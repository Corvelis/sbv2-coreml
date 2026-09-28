"""Export the unchanged upstream decoder directly from its checkpoint.

Core ML input/output names match the existing native runtime. No ONNX graph names
or ONNX exporter version is involved in this path.
"""
from __future__ import annotations
import argparse
import json
import shutil
import sys
import tempfile
from pathlib import Path
import numpy as np
import torch
import coremltools as ct
from coremltools.converters.mil.mil.scope import ScopeSource

def fast_precision(op):
    # Early decoder/conditioning layers are numerically sensitive for quiet inputs.
    # Preserve FP32 there, while the large late waveform convolutions use FP16.
    names = op.scopes.get(ScopeSource.TORCHSCRIPT_MODULE_NAME, [])
    if any(name in names for name in ('emb_g', 'conv_pre', 'cond', 'conv_post')):
        return False
    if len(names) > 1 and names[1] in ('0', '1', '2'):
        return False
    return True

class Decoder(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.emb_g = model.emb_g
        self.dec = model.dec
    def forward(self, z, sid):
        return self.dec(z, g=self.emb_g(sid).unsqueeze(-1))

def main():
    parser = argparse.ArgumentParser()
    for name in ['source-root', 'checkpoint', 'config', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    sys.path.insert(0, str(args.source_root.resolve()))
    from style_bert_vits2.models.hyper_parameters import HyperParameters
    from style_bert_vits2.models.infer import get_net_g
    from ._conversion.validate_voice_coreml_pipeline import compare
    from .weights import validate_loaded_weights
    torch.set_num_threads(4)
    torch.manual_seed(20260928)
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='sbv2_decoder_') as temporary:
        link = Path(temporary) / 'voice.safetensors'
        link.symlink_to(args.checkpoint.resolve())
        config = HyperParameters.load_from_json(args.config)
        model = get_net_g(str(link), config.version, 'cpu', config).eval()
        validate_loaded_weights(model, args.checkpoint)
        # Materialize weight normalization in FP32 before the FP16 conversion pass,
        # exactly as inference-time ONNX export does. Check the rewrite itself.
        probe = torch.randn(1, 192, 32)
        speaker = torch.zeros(1, dtype=torch.int32)
        with torch.no_grad():
            before = Decoder(model)(probe, speaker).clone()
            model.dec.remove_weight_norm()
            after = Decoder(model)(probe, speaker)
            if not torch.equal(before, after):
                raise ValueError('Removing decoder weight normalization changed the FP32 reference')
        module = Decoder(model).eval()
        rng = np.random.default_rng(20260928)
        records = []
        with torch.no_grad():
            for length, precision, name in [
                (None, ct.precision.FLOAT32, 'decoder_combined_flex'),
                (256, ct.precision.FLOAT16, 'decoder_combined_len_256_fp16'),
                (32, ct.precision.FLOAT16, 'decoder_combined_len_32_fp16')]:
                shape = (1, 192, length or 105)
                z = torch.from_numpy((rng.standard_normal(shape) * .2).astype(np.float32))
                sid = torch.zeros((1,), dtype=torch.int32)
                traced = torch.jit.trace(module, (z, sid), check_trace=False)
                path = args.output / (name + '.mlpackage')
                def export(compute_precision):
                    return ct.convert(traced, source='pytorch', convert_to='mlprogram',
                    minimum_deployment_target=ct.target.iOS18,
                    compute_precision=compute_precision,
                    inputs=[ct.TensorType(name='_Mul_9_output_0', shape=(1, 192, length or ct.RangeDim(16, 512, default=105)), dtype=np.float32),
                            ct.TensorType(name='sid', shape=(1,), dtype=np.int32)],
                    outputs=[ct.TensorType(name='output', dtype=np.float32)], package_dir=str(path))
                cases = []
                for n in ([16, 23, 64, 256, 512] if length is None else [length]):
                    for speaker in sorted(set(config.data.spk2id.values())):
                        value = (rng.standard_normal((1, 192, n)) * .2).astype(np.float32)
                        speaker_value = np.array([speaker], dtype=np.int32)
                        expected = module(torch.from_numpy(value), torch.from_numpy(speaker_value)).numpy()
                        cases.append((n, speaker, value, speaker_value, expected))
                profiles = [('float32', ct.precision.FLOAT32)] if length is None else [
                    ('mixed-fp32-fp16', ct.transform.FP16ComputePrecision(op_selector=fast_precision)),
                    ('float32', ct.precision.FLOAT32)]
                attempts = []
                for label, compute_precision in profiles:
                    if path.exists(): shutil.rmtree(path)
                    mlmodel = export(compute_precision)
                    tested = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
                    checks = []
                    for n, speaker, value, speaker_value, expected in cases:
                        actual = tested.predict({'_Mul_9_output_0': value, 'sid': speaker_value})['output']
                        if not np.isfinite(actual).all(): raise ValueError('Non-finite decoder output')
                        checks.append({'frames': n, 'speaker': speaker, **compare(expected, actual)})
                    snr, maximum = (60, 1e-3) if label == 'float32' else (35, .05)
                    passed = all(c['snr_db'] >= snr and c['max_abs'] <= maximum for c in checks)
                    attempts.append({'precision': label, 'passed': passed, 'checks': checks})
                    if passed: break
                    del tested, mlmodel
                    print(f'{name}: {label} exceeded error bounds; retrying at full precision', flush=True)
                if not passed: raise ValueError(f'Decoder validation failed: {attempts}')
                records.append({'name': name, 'mlpackage': path.name, 'precision': label,
                    'checks': checks, 'attempts': attempts})
                del tested, mlmodel, traced
                print(f'Validated {name}', flush=True)
        (args.output / 'decoder_validation.json').write_text(json.dumps(records, indent=2) + '\n')

if __name__ == '__main__': main()
