#!/usr/bin/env python3
"""Export voice-specific Style-Bert-VITS2 inference blocks from original weights.

Exported blocks are used by the native Core ML runtime.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from sbv2_coreml.weights import validate_loaded_weights

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sbv2_coreml._conversion.lib.coreml_sdp_spline import coreml_piecewise_spline


def parse_lengths(value: str) -> list[int]:
    lengths = [int(part.strip()) for part in value.split(",") if part.strip()]
    if not lengths or sorted(set(lengths)) != lengths or lengths[0] < 2:
        raise argparse.ArgumentTypeError("lengths must be sorted, unique integers >= 2")
    return lengths


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True, help="Style-Bert-VITS2 Python source root")
    parser.add_argument("--checkpoint", type=Path, required=True, help="Voice .aivm or .safetensors")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--text-lengths", type=parse_lengths, default=[64, 128])
    parser.add_argument("--flow-lengths", type=parse_lengths, default=[64, 128, 256, 512])
    parser.add_argument("--compute-precision", choices=("float16", "float32"), default="float32")
    parser.add_argument("--validate", action="store_true", help="Compare each converted block with PyTorch on macOS")
    return parser.parse_args()


class PreBlock(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.enc_p = model.enc_p
        self.dp = model.dp
        self.emb_g = model.emb_g

    def forward(self, phones, lengths, speaker, tones, languages, bert, style):
        g = self.emb_g(speaker).unsqueeze(-1)
        x, m, logs, mask = self.enc_p(phones, lengths, tones, languages, bert, style, g=g)
        logw = self.dp(x, mask, g=g)
        return x, m, logs, mask, g, logw


class SdpBlock(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.sdp = model.sdp

    def forward(self, x, mask, g, noise):
        sdp = self.sdp
        hidden = sdp.pre(x.detach()) + sdp.cond(g.detach())
        hidden = sdp.convs(hidden, mask)
        hidden = sdp.proj(hidden) * mask
        flows = list(reversed(sdp.flows))
        flows = flows[:-2] + [flows[-1]]
        # The caller supplies standard-normal noise already multiplied by
        # noise_scale_w, so the model supports the original runtime setting.
        z = noise
        for flow in flows:
            z = flow(z, mask, g=hidden, reverse=True)
        return z[:, :1, :]


class FlowBlock(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.flow = model.flow

    def forward(self, z, mask, g):
        return self.flow(z, mask, g=g, reverse=True)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export_block(
    module: torch.nn.Module,
    inputs: tuple[torch.Tensor, ...],
    input_names: list[str],
    output_names: list[str],
    package: Path,
    precision: str,
    validate: bool,
) -> dict[str, object]:
    if package.exists():
        shutil.rmtree(package)
    with torch.no_grad():
        traced = torch.jit.trace(module.eval(), inputs, check_trace=False)
        model = ct.convert(
            traced,
            source="pytorch",
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.iOS16,
            compute_precision=(ct.precision.FLOAT32 if precision == "float32" else ct.precision.FLOAT16),
            inputs=[ct.TensorType(name=name, shape=tuple(value.shape)) for name, value in zip(input_names, inputs, strict=True)],
            outputs=[ct.TensorType(name=name) for name in output_names],
            package_dir=str(package),
        )
        differences: dict[str, float] = {}
        if validate:
            generator = torch.Generator().manual_seed(7)
            validation_inputs: list[torch.Tensor] = []
            for name, value in zip(input_names, inputs, strict=True):
                if name == "phones":
                    candidate = torch.randint(1, 100, value.shape, generator=generator, dtype=value.dtype)
                elif name == "tones":
                    candidate = torch.randint(1, 10, value.shape, generator=generator, dtype=value.dtype)
                elif name == "lengths":
                    candidate = torch.tensor([max(2, inputs[0].shape[-1] - 8)], dtype=value.dtype)
                elif name in ("speaker", "languages"):
                    candidate = torch.zeros_like(value)
                elif name == "mask":
                    candidate = torch.ones_like(value)
                else:
                    candidate = torch.randn(value.shape, generator=generator, dtype=value.dtype) * 0.2
                validation_inputs.append(candidate)
            expected = module(*validation_inputs)
            if not isinstance(expected, tuple):
                expected = (expected,)
            actual = model.predict({name: value.numpy() for name, value in zip(input_names, validation_inputs, strict=True)})
            for name, tensor in zip(output_names, expected, strict=True):
                differences[name] = float(np.max(np.abs(actual[name] - tensor.numpy())))
    return {"mlpackage": package.name, "inputs": input_names, "outputs": output_names,
            "compute_precision": precision, "max_abs_vs_pytorch": differences}


def main() -> int:
    args = parse_args()
    if not args.source_root.is_dir() or not args.checkpoint.is_file() or not args.config.is_file():
        raise FileNotFoundError("Source root, checkpoint, and config must exist")
    sys.path.insert(0, str(args.source_root.resolve()))
    from style_bert_vits2.models.hyper_parameters import HyperParameters
    from style_bert_vits2.models.infer import get_net_g
    from style_bert_vits2.models import modules

    args.output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="sbv2_voice_") as temp_dir:
        checkpoint_for_loader = args.checkpoint.resolve()
        if checkpoint_for_loader.suffix != ".safetensors":
            link = Path(temp_dir) / "voice.safetensors"
            link.symlink_to(checkpoint_for_loader)
            checkpoint_for_loader = link
        config = HyperParameters.load_from_json(args.config)
        model = get_net_g(str(checkpoint_for_loader), config.version, "cpu", config).eval()
        validate_loaded_weights(model, args.checkpoint)
        pre = PreBlock(model).eval()
        sdp = SdpBlock(model).eval()
        flow = FlowBlock(model).eval()
        original_spline = modules.piecewise_rational_quadratic_transform
        if args.validate:
            generator = torch.Generator().manual_seed(23)
            spline_inputs = torch.randn((1, 1, 128), generator=generator) * 1.5
            widths = torch.randn((1, 1, 128, 10), generator=generator)
            heights = torch.randn((1, 1, 128, 10), generator=generator)
            derivatives = torch.randn((1, 1, 128, 9), generator=generator)
            original_values = original_spline(
                spline_inputs, widths, heights, derivatives, inverse=True, tails="linear"
            )
            rewritten_values = coreml_piecewise_spline(
                spline_inputs, widths, heights, derivatives, inverse=True, tails="linear"
            )
            if any(
                not torch.allclose(a, b, atol=1e-6, rtol=1e-6)
                for a, b in zip(original_values, rewritten_values, strict=True)
            ):
                raise ValueError("Core ML SDP spline differs from the original implementation")
        modules.piecewise_rational_quadratic_transform = coreml_piecewise_spline
        records: list[dict[str, object]] = []
        try:
            for length in args.text_lengths:
                pre_inputs = (
                    torch.ones((1, length), dtype=torch.int32),
                    torch.tensor([length], dtype=torch.int32),
                    torch.zeros((1,), dtype=torch.int32),
                    torch.ones((1, length), dtype=torch.int32),
                    torch.zeros((1, length), dtype=torch.int32),
                    torch.zeros((1, 1024, length), dtype=torch.float32),
                    torch.zeros((1, 256), dtype=torch.float32),
                )
                pre_record = export_block(pre, pre_inputs,
                    ["phones", "lengths", "speaker", "tones", "languages", "bert", "style"],
                    ["x", "m", "logs", "mask", "g", "logw"],
                    args.output_dir / f"pre_{length}.mlpackage", args.compute_precision, args.validate)
                pre_record.update(block="pre", sequence_length=length)
                records.append(pre_record)
                sdp_inputs = (
                    torch.zeros((1, 192, length)), torch.ones((1, 1, length)),
                    torch.zeros((1, 512, 1)), torch.zeros((1, 2, length)),
                )
                sdp_record = export_block(sdp, sdp_inputs, ["x", "mask", "g", "noise"],
                    ["logw"], args.output_dir / f"sdp_{length}.mlpackage",
                    args.compute_precision, args.validate)
                sdp_record.update(block="sdp", sequence_length=length)
                sdp_record["noise_semantics"] = "standard_normal_times_noise_scale_w"
                records.append(sdp_record)
            for length in args.flow_lengths:
                flow_inputs = (
                    torch.zeros((1, 192, length)), torch.ones((1, 1, length)),
                    torch.zeros((1, 512, 1)),
                )
                flow_record = export_block(flow, flow_inputs, ["z", "mask", "g"], ["output"],
                    args.output_dir / f"flow_{length}.mlpackage", args.compute_precision, args.validate)
                flow_record.update(block="flow", sequence_length=length)
                records.append(flow_record)
        finally:
            modules.piecewise_rational_quadratic_transform = original_spline

    manifest = {
        "checkpoint_sha256": sha256(args.checkpoint),
        "config_sha256": sha256(args.config),
        "status": "coreml_voice_opt_in",
        "blocks": records,
    }
    manifest_path = args.output_dir / "coreml_voice_blocks_manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
