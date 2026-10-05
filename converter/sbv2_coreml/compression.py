"""Compress shared BERT weights without changing the voice model or tensor interface."""
from __future__ import annotations

import argparse
import gc
import json
import shutil
from pathlib import Path

from .assets import write_json


def compress_model(model, mode: str):
    import coremltools as ct
    import coremltools.optimize.coreml as cto
    import numpy as np

    if mode == 'int8':
        config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(
            mode='linear_symmetric', dtype='int8', granularity='per_block',
            block_size=32, weight_threshold=16384))
        return cto.linear_quantize_weights(model, config)
    if mode != 'fp16-weights':
        raise ValueError(f'Unknown weight storage mode: {mode}')

    from coremltools.converters.mil.mil import Builder as mb, types
    from coremltools.converters.mil.mil.passes.graph_pass import AbstractGraphPass

    class PackFP16(AbstractGraphPass):
        def apply(self, program):
            def visit(block):
                for op in list(block.operations):
                    for nested in op.blocks:
                        visit(nested)
                    if op.op_type != 'const' or op.outputs[0].dtype != types.fp32:
                        continue
                    value = op.outputs[0].val
                    if not isinstance(value, np.ndarray) or value.ndim < 2 or value.size < 16384:
                        continue
                    if not np.isfinite(value).all() or np.max(np.abs(value)) > 65504:
                        raise ValueError('Weight cannot be safely represented in FP16')
                    with block:
                        packed = mb.constexpr_cast(source_val=value.astype(np.float16),
                            output_dtype='fp32', name=op.outputs[0].name + '_packed', before_op=op)
                    block.replace_uses_of_var_after_op(anchor_op=op, old_var=op.outputs[0], new_var=packed)
                    block.remove_ops([op])
            for function in program.functions.values():
                visit(function)

    # Pinned coremltools 9.0 retains the existing model description and precision.
    return ct.models.utils._apply_graph_pass(model, PackFP16())


def compress_bert(source: Path, output: Path, mode: str) -> None:
    import coremltools as ct
    if output.exists():
        raise ValueError('Output already exists')
    manifest = json.loads((source / 'coreml_blocks/coreml_bert_blocks_manifest.json').read_text())
    if {entry['block'] for entry in manifest['blocks']} != {'prefix.0', 'group.1-23-conv'}:
        raise ValueError('Expected the shared JP-Extra BERT prefix/group packages')
    for entry in manifest['blocks']:
        name = entry['mlpackage']
        if Path(name).name != name or not name.endswith('.mlpackage'):
            raise ValueError('BERT package paths must be local package names')
        if entry.get('weight_compression') or entry.get('compute_precision') != 'float32':
            raise ValueError('Supply the original uncompressed FP32 BERT')
    blocks = output / 'coreml_blocks'
    blocks.mkdir(parents=True)
    shutil.copy2(source / 'vocab.txt', output / 'vocab.txt')
    records = []
    for entry in manifest['blocks']:
        src = source / 'coreml_blocks' / entry['mlpackage']
        dst = blocks / entry['mlpackage']
        print(f"Compressing {entry['block']}: {mode}", flush=True)
        model = ct.models.MLModel(str(src), skip_model_load=True, compute_units=ct.ComputeUnit.CPU_ONLY)
        result = compress_model(model, mode)
        result.save(str(dst))
        size = lambda root: sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
        records.append({'block': entry['block'], 'source_bytes': size(src), 'compressed_bytes': size(dst)})
        entry['weight_compression'] = {'mode': mode, 'compute_precision': 'float32'}
        if mode == 'int8':
            entry['weight_compression'].update(granularity='per_block', block_size=32)
        del model, result
        gc.collect()
    write_json(blocks / 'coreml_bert_blocks_manifest.json', manifest)
    write_json(output / 'compression_report.json', {'mode': mode, 'component': 'bert',
        'compute_precision': 'float32', 'voice_weights_changed': False,
        'perceptual_quality_validated': False, 'records': records})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['int8', 'fp16-weights'], required=True)
    args = parser.parse_args()
    compress_bert(args.input, args.output, args.mode)


if __name__ == '__main__':
    main()
