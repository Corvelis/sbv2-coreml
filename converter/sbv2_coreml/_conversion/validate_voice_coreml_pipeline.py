#!/usr/bin/env python3
"""Compare a complete experimental voice Core ML chain with original PyTorch."""

from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch

PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from sbv2_coreml._conversion.build_coreml_voice_from_checkpoint import (
    FlowBlock,
    PreBlock,
    SdpBlock,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--style-vectors", type=Path, required=True)
    parser.add_argument("--coreml-blocks", type=Path, required=True)
    parser.add_argument("--decoder", type=Path, required=True)
    parser.add_argument("--phoneme-length", type=int, default=32)
    parser.add_argument("--length-scale", type=float, default=1.0)
    parser.add_argument("--json-out", type=Path)
    parser.add_argument("--swift-fixture-dir", type=Path)
    return parser.parse_args()


def compare(expected: np.ndarray, actual: np.ndarray) -> dict[str, float]:
    if expected.shape != actual.shape:
        raise ValueError(f"Shape mismatch: {expected.shape} vs {actual.shape}")
    difference = expected.astype(np.float64) - actual.astype(np.float64)
    error_energy = float(np.sum(difference * difference))
    signal_energy = float(np.sum(expected.astype(np.float64) ** 2))
    return {
        "max_abs": float(np.max(np.abs(difference))),
        "rmse": float(np.sqrt(np.mean(difference * difference))),
        "snr_db": float(10 * np.log10(signal_energy / error_energy)) if error_energy else 300.0,
    }


def expand(m: np.ndarray, logs: np.ndarray, mask: np.ndarray, logw: np.ndarray, scale: float):
    counts = np.ceil(np.exp(logw) * mask * scale).astype(np.int64).reshape(-1)
    indices = np.repeat(np.arange(counts.size), counts)
    if indices.size == 0:
        raise ValueError("Predicted duration contains no audio frames")
    return m[:, :, indices], logs[:, :, indices], int(indices.size)


def main() -> int:
    args = parse_args()
    sys.path.insert(0, str(args.source_root.resolve()))
    from style_bert_vits2.models.hyper_parameters import HyperParameters
    from style_bert_vits2.models.infer import get_net_g

    torch.set_num_threads(4)
    with tempfile.TemporaryDirectory(prefix="sbv2_voice_validate_") as temp_dir:
        checkpoint = args.checkpoint.resolve()
        if checkpoint.suffix != ".safetensors":
            link = Path(temp_dir) / "voice.safetensors"
            link.symlink_to(checkpoint)
            checkpoint = link
        config = HyperParameters.load_from_json(args.config)
        voice = get_net_g(str(checkpoint), config.version, "cpu", config).eval()
        pre_reference = PreBlock(voice).eval()
        sdp_reference = SdpBlock(voice).eval()
        flow_reference = FlowBlock(voice).eval()

        rng = np.random.default_rng(17)
        length = 128
        active = args.phoneme_length
        if not 2 <= active <= length:
            raise ValueError("--phoneme-length must be between 2 and 128")
        style = np.load(args.style_vectors)[:1].astype(np.float32)
        pre_inputs = {
            "phones": rng.integers(1, 100, (1, length), dtype=np.int32),
            "lengths": np.array([active], dtype=np.int32),
            "speaker": np.array([0], dtype=np.int32),
            "tones": rng.integers(1, 10, (1, length), dtype=np.int32),
            "languages": np.zeros((1, length), dtype=np.int32),
            "bert": rng.normal(0, 0.2, (1, 1024, length)).astype(np.float32),
            "style": style,
        }
        pre_names = ["phones", "lengths", "speaker", "tones", "languages", "bert", "style"]
        with torch.no_grad():
            ref_pre = pre_reference(*(torch.from_numpy(pre_inputs[name]) for name in pre_names))
        ref = dict(zip(["x", "m", "logs", "mask", "g", "logw"],
                       (value.numpy() for value in ref_pre), strict=True))

        block_dir = args.coreml_blocks
        pre_model = ct.models.MLModel(str(block_dir / "pre_128.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        sdp_model = ct.models.MLModel(str(block_dir / "sdp_128.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
        decoder_model = ct.models.MLModel(str(args.decoder), compute_units=ct.ComputeUnit.CPU_ONLY)
        core = pre_model.predict(pre_inputs)

        sdp_noise = rng.normal(0, 1, (1, 2, length)).astype(np.float32) * 0.8
        with torch.no_grad():
            ref_sdp = sdp_reference(
                *(torch.from_numpy(value) for value in (ref["x"], ref["mask"], ref["g"], sdp_noise))
            ).numpy()
        core_sdp = sdp_model.predict({
            "x": core["x"], "mask": core["mask"], "g": core["g"], "noise": sdp_noise,
        })["logw"]
        ref_logw = 0.2 * ref_sdp + 0.8 * ref["logw"]
        core_logw = 0.2 * core_sdp + 0.8 * core["logw"]
        ref_m, ref_logs, ref_frames = expand(ref["m"], ref["logs"], ref["mask"], ref_logw, args.length_scale)
        core_m, core_logs, core_frames = expand(core["m"], core["logs"], core["mask"], core_logw, args.length_scale)
        if ref_frames != core_frames:
            raise ValueError(f"Predicted duration changed: {ref_frames} vs {core_frames}")
        flow_length = next((length for length in (64, 128, 256, 512) if ref_frames <= length), None)
        if flow_length is None or ref_frames < 16:
            raise ValueError(f"Expected 16..512 frames for this validator, got {ref_frames}")
        flow_model = ct.models.MLModel(
            str(block_dir / f"flow_{flow_length}.mlpackage"),
            compute_units=ct.ComputeUnit.CPU_ONLY,
        )

        latent_noise = rng.normal(0, 1, (1, 192, ref_frames)).astype(np.float32)
        ref_zp = ref_m + latent_noise * np.exp(ref_logs) * 0.6
        core_zp = core_m + latent_noise * np.exp(core_logs) * 0.6
        with torch.no_grad():
            ref_z = flow_reference(
                torch.from_numpy(ref_zp),
                torch.ones((1, 1, ref_frames)),
                torch.from_numpy(ref["g"]),
            ).numpy()
        padded_zp = np.pad(core_zp, ((0, 0), (0, 0), (0, flow_length - ref_frames)))
        padded_mask = np.pad(np.ones((1, 1, ref_frames), dtype=np.float32),
                             ((0, 0), (0, 0), (0, flow_length - ref_frames)))
        core_z = flow_model.predict({"z": padded_zp, "mask": padded_mask, "g": core["g"]})["output"][:, :, :ref_frames]
        with torch.no_grad():
            ref_wave = voice.dec(torch.from_numpy(ref_z), g=torch.from_numpy(ref["g"])).numpy()
        core_wave = decoder_model.predict({
            "_Mul_9_output_0": core_z, "sid": np.array([0], dtype=np.int32),
        })["output"]

        result = {
            "phonemes": active,
            "frames": ref_frames,
            "flow_model_frames": flow_length,
            "pre_x": compare(ref["x"], core["x"]),
            "sdp_logw": compare(ref_sdp, core_sdp),
            "latent_before_flow": compare(ref_zp, core_zp),
            "latent_after_flow": compare(ref_z, core_z),
            "waveform": compare(ref_wave, core_wave),
        }
        if args.swift_fixture_dir:
            fixture = args.swift_fixture_dir
            fixture.mkdir(parents=True, exist_ok=True)
            (fixture / "inputs.json").write_text(json.dumps({
                "phonemes": pre_inputs["phones"][0, :active].tolist(),
                "tones": pre_inputs["tones"][0, :active].tolist(),
                "languages": pre_inputs["languages"][0, :active].tolist(),
                "frames": ref_frames,
            }, indent=2) + "\n", encoding="utf-8")
            pre_inputs["bert"][0, :, :active].T.astype(np.float32).tofile(fixture / "bert_rows.bin")
            style.reshape(-1).tofile(fixture / "style.bin")
            sdp_noise.reshape(-1).tofile(fixture / "sdp_noise.bin")
            latent_noise.reshape(-1).tofile(fixture / "latent_noise.bin")
            ref_wave.reshape(-1).astype(np.float32).tofile(fixture / "reference_wave.bin")
        print(json.dumps(result, indent=2))
        if args.json_out:
            args.json_out.parent.mkdir(parents=True, exist_ok=True)
            args.json_out.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
