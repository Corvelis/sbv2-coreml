#!/usr/bin/env python3
"""Share identical weights across a voice's fixed shapes, without quantization.

Writes a NEW voice directory. The original bundle and shared BERT are untouched.
Requires Core ML Tools 9 and iOS 18+ / macOS 15+ at inference time.
"""
from __future__ import annotations

import argparse
import gc
import json
import shutil
import tempfile
from pathlib import Path

BLOCKS = ["pre_64", "pre_128", "sdp_64", "sdp_128",
          "flow_64", "flow_128", "flow_256", "flow_512"]
DECODERS = ["decoder_combined_flex", "decoder_combined_len_256_fp16",
            "decoder_combined_len_32_fp16", "decoder_combined_len_384_fp16"]
PACKAGE = "voice_shared.mlpackage"


def source_packages(source: Path) -> dict[str, Path]:
    packages = {name: source / "coreml_voice" / f"{name}.mlpackage" for name in BLOCKS}
    packages[DECODERS[0]] = source / "hybrid" / f"{DECODERS[0]}.mlpackage"
    for path in packages.values():
        if not (path / "Manifest.json").is_file():
            raise FileNotFoundError(path)
    for name in DECODERS[1:]:
        path = source / "hybrid" / f"{name}.mlpackage"
        if (path / "Manifest.json").is_file():
            packages[name] = path
    return packages


def directory_bytes(directory: Path) -> int:
    return sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())


def verify_predictions(packages: dict[str, Path], merged: Path) -> dict:
    import coremltools as ct
    import numpy as np

    with tempfile.TemporaryDirectory(prefix="sbv2_merged_") as cache:
        compiled = ct.models.utils.compile_model(str(merged), destination_path=str(Path(cache) / "shared.mlmodelc"))
        return _compare_predictions(packages, Path(compiled))


def _compare_predictions(packages: dict[str, Path], merged: Path) -> dict:
    import coremltools as ct
    import numpy as np

    results = {}
    for name, path in packages.items():
        spec = ct.utils.load_spec(str(path))
        # The flexible decoder serves short final windows, including <32 frames.
        lengths = [16, 23, 32, 64] if name == DECODERS[0] else [None]
        with tempfile.TemporaryDirectory(prefix="sbv2_compare_") as cache:
            compiled = Path(ct.models.utils.compile_model(str(path), destination_path=str(Path(cache) / "source.mlmodelc")))
            original = ct.models.CompiledMLModel(str(compiled), compute_units=ct.ComputeUnit.CPU_ONLY)
            compact = ct.models.CompiledMLModel(str(merged), function_name=name, compute_units=ct.ComputeUnit.CPU_ONLY)
            checks = []
            for length in lengths:
                rng = np.random.default_rng(20260926)
                inputs = {}
                for feature in spec.description.input:
                    shape = list(feature.type.multiArrayType.shape)
                    if length is not None and feature.name == "_Mul_9_output_0":
                        shape[-1] = length
                    value = (rng.standard_normal(shape) * 0.1).astype(np.float32)
                    if feature.name in ("phones", "tones", "languages", "speaker", "sid"):
                        value.fill(0 if feature.name != "phones" else 1)
                    elif feature.name == "lengths":
                        value.fill(int(name.split('_')[-1]) - 8)
                    elif feature.name == "mask":
                        value.fill(1)
                        value[..., -8:] = 0
                    if feature.type.multiArrayType.dataType == 131104:
                        value = value.astype(np.int32)
                    inputs[feature.name] = value
                expected = original.predict(inputs)
                actual = compact.predict(inputs)
                errors = {}
                for key, reference in expected.items():
                    candidate = actual[key]
                    if not np.isfinite(candidate).all() or candidate.shape != reference.shape:
                        raise ValueError(f"Invalid output for {name}/{key}")
                    error = float(np.max(np.abs(reference - candidate)))
                    errors[key] = error
                    # Packaging is intended to preserve results exactly. Stop
                    # instead of silently accepting a voice-changing conversion.
                    if not np.array_equal(reference, candidate):
                        raise ValueError(f"Output changed for {name}/{key}: {error}")
                checks.append({"length": length, "max_abs": errors})
            results[name] = checks
            del original, compact
            gc.collect()
        print(f"IDENTICAL {name}", flush=True)
    return results


def compact_voice(source: Path, destination: Path, validate: bool = True) -> dict:
    import coremltools as ct

    source = source.resolve()
    destination = destination.resolve()
    if destination.exists() or source in destination.parents:
        raise ValueError("Destination must be new and outside the source voice")
    packages = source_packages(source)
    for name in ("config.json", "style_vectors.npy"):
        if not (source / name).is_file():
            raise FileNotFoundError(source / name)
    manifest = json.loads((source / "coreml_voice/coreml_voice_blocks_manifest.json").read_text())
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".sbv2_compact_", dir=destination.parent) as temporary:
        stage = Path(temporary) / destination.name
        blocks = stage / "coreml_voice"
        blocks.mkdir(parents=True)
        descriptor = ct.utils.MultiFunctionDescriptor()
        for name, package in packages.items():
            descriptor.add_function(str(package), "main", name)
        descriptor.default_function_name = BLOCKS[0]
        merged = blocks / PACKAGE
        ct.utils.save_multifunction(descriptor, str(merged))
        for name in ("config.json", "style_vectors.npy", "voice_identity.json", "aivis_source.json", "LICENSE.md"):
            if (source / name).is_file():
                shutil.copy2(source / name, stage / name)
        manifest["multifunction"] = {"mlpackage": PACKAGE, "functions": list(packages)}
        for block in manifest.get("blocks", []):
            block["function_name"] = Path(block["mlpackage"]).stem
            block["mlpackage"] = PACKAGE
        (blocks / "coreml_voice_blocks_manifest.json").write_text(json.dumps(manifest, indent=2))
        report = {
            "source": str(source), "destination": str(destination),
            "source_package_bytes": sum(directory_bytes(path) for path in packages.values()),
            "compact_package_bytes": directory_bytes(merged),
            "quantization": "none", "validation": "not_run",
        }
        print(json.dumps(report), flush=True)
        if validate:
            report["predictions"] = verify_predictions(packages, merged)
            report["validation"] = "all_outputs_bit_identical_cpu"
        (stage / "compaction_report.json").write_text(json.dumps(report, indent=2))
        stage.rename(destination)
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    parser.add_argument("--skip-validation", action="store_true", help="For experiments only; do not deploy unchecked output")
    args = parser.parse_args()
    print(json.dumps(compact_voice(args.source, args.destination, not args.skip_validation), indent=2))


if __name__ == "__main__":
    main()
