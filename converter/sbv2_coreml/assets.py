"""Input inspection, provenance and checksum-verified downloads. No model execution."""
from __future__ import annotations
import base64
import hashlib
import json
import os
import re
import shutil
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

ARCHITECTURE = "Style-Bert-VITS2 (JP-Extra)"
UPSTREAM_REVISION = "66de777e06392c0f313600be03c43ef96658b244"

def prepare_upstream(source: Path, destination: Path) -> dict:
    """Keep optional upstream ORT helpers lazy in an isolated conversion copy.

    The pinned upstream imports ORT from utils/__init__.py, even when only the
    PyTorch models are used. No inference math is changed and originals stay intact.
    """
    shutil.copytree(source / 'style_bert_vits2', destination / 'style_bert_vits2',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for name in ('LICENSE', 'LGPL_LICENSE'):
        if (source / name).is_file(): shutil.copy2(source / name, destination / name)
    target = destination / 'style_bert_vits2/utils/__init__.py'
    before = target.read_text()
    marker = '    # ONNX セッションに対応する SessionOptions を取得'
    if '\nimport onnxruntime\n' not in before:
        return {'description': 'No eager ORT import in supplied source; no patch applied'}
    if marker not in before:
        raise ValueError('Unsupported upstream ORT utility layout; use the pinned upstream revision')
    after = before.replace('\nimport onnxruntime\n', '\n', 1).replace(marker, '    import onnxruntime\n\n' + marker, 1)
    if 'from __future__ import annotations' not in after:
        after = 'from __future__ import annotations\n\n' + after
    original = digest(target)
    target.write_text(after)
    return {'description': 'Move optional ORT import into the unused ONNX helper; postpone type annotations',
        'file': 'style_bert_vits2/utils/__init__.py', 'source_sha256': original, 'patched_sha256': digest(target)}

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""): h.update(block)
    return h.hexdigest()

def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, allow_nan=False) + "\n")

def request_json(url: str):
    with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "sbv2-coreml/0.1"}), timeout=60) as response:
        return json.load(response)

def download(url: str, destination: Path, expected_sha256: str | None = None) -> Path:
    if not url.startswith("https://"):
        raise ValueError("Downloads require HTTPS")
    if expected_sha256 and not re.fullmatch(r"[0-9a-f]{64}", expected_sha256):
        raise ValueError("Invalid SHA-256")
    if destination.is_file() and expected_sha256 and digest(destination) == expected_sha256:
        return destination
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, prefix=".download-", delete=False) as stream:
        staging = Path(stream.name)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "sbv2-coreml/0.1"}), timeout=120) as response:
                if not response.url.startswith("https://"): raise ValueError("Insecure download redirect")
                for block in iter(lambda: response.read(1024 * 1024), b""): stream.write(block)
            stream.close()
            if expected_sha256 and digest(staging) != expected_sha256:
                raise ValueError("Downloaded file checksum does not match the selected model revision")
            staging.replace(destination)
        finally: staging.unlink(missing_ok=True)
    return destination

def safe_extract(archive: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination.resolve()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (root / member.name).resolve()
            if not target.is_relative_to(root) or not (member.isfile() or member.isdir()):
                raise ValueError(f"Unsafe archive member: {member.name}")
        tar.extractall(destination, filter="data")

def upstream(cache: Path) -> Path:
    lock = json.loads(Path(__file__).with_name("upstream.lock.json").read_text())
    target = cache / f"Style-Bert-VITS2-{UPSTREAM_REVISION}"
    if (target / ".sbv2-source-sha256").is_file() and (target / ".sbv2-source-sha256").read_text().strip() == lock["sha256"]:
        return target
    archive = download(lock["url"], cache / "upstream.tar.gz", lock["sha256"])
    safe_extract(archive, cache)
    (target / ".sbv2-source-sha256").write_text(lock["sha256"] + "\n")
    return target

def aivis_metadata(url: str) -> tuple[str, dict, dict]:
    parsed = urllib.parse.urlparse(url)
    match = re.fullmatch(r"/aivm-models/([0-9a-fA-F-]{36})/?", parsed.path)
    if parsed.scheme != "https" or parsed.netloc != "hub.aivis-project.com" or not match:
        raise ValueError("Expected https://hub.aivis-project.com/aivm-models/<UUID>")
    import uuid
    identifier = str(uuid.UUID(match[1]))
    metadata = request_json(f"https://api.aivis-project.com/v1/aivm-models/{identifier}")
    model = next((m for m in metadata.get("model_files", []) if m.get("model_type") == "AIVM"), None)
    if model is None: raise ValueError("This model has no downloadable AIVM. Original .aivm/.safetensors weights are required; AIVMX alone is unsupported.")
    if model.get("model_architecture") != ARCHITECTURE: raise ValueError("Only JP-Extra is supported")
    return identifier, metadata, model

def fetch_aivis(url: str, cache: Path) -> tuple[Path, dict]:
    identifier, metadata, model = aivis_metadata(url)
    checksum = model.get("checksum", "")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum): raise ValueError("AivisHub did not provide a SHA-256")
    print(f"{metadata['name']} {model['version']} / {model.get('license_type', 'custom license')}", flush=True)
    path = download(f"https://api.aivis-project.com/v1/aivm-models/{identifier}/download?model_type=AIVM",
        cache / f"{identifier}-{checksum[:12]}.aivm", checksum)
    # Preserve only model provenance, not account metadata or private access fields.
    return path, {"url": f"https://hub.aivis-project.com/aivm-models/{identifier}",
        "uuid": identifier, "name": metadata["name"], "version": model["version"],
        "sha256": checksum, "license_type": model.get("license_type")}

def extract_aivm(path: Path, output: Path) -> tuple[Path, Path, dict]:
    from safetensors import safe_open
    import numpy as np
    import io
    with safe_open(str(path), framework="np") as model: meta = model.metadata() or {}
    manifest = json.loads(meta["aivm_manifest"])
    if manifest.get("model_architecture") != ARCHITECTURE or manifest.get("model_format") != "Safetensors":
        raise ValueError("Expected JP-Extra Safetensors AIVM")
    config = json.loads(meta["aivm_hyper_parameters"])
    styles = base64.b64decode(meta["aivm_style_vectors"], validate=True)
    values = np.load(io.BytesIO(styles), allow_pickle=False)
    if values.ndim != 2 or values.shape[1] != 256 or not np.isfinite(values).all():
        raise ValueError("Invalid style vectors")
    output.mkdir(parents=True, exist_ok=True)
    config_path, style_path = output / "config.json", output / "style_vectors.npy"
    write_json(config_path, config); style_path.write_bytes(styles)
    if isinstance(manifest.get("license"), str) and manifest["license"].strip():
        (output / "LICENSE.md").write_text(manifest["license"] + "\n")
    return config_path, style_path, {k: manifest.get(k) for k in ["uuid", "name", "version", "model_architecture", "license"]}

def validate_config(path: Path, styles: Path) -> dict:
    import numpy as np
    config = json.loads(path.read_text())
    data, model = config["data"], config["model"]
    expected = {"inter_channels": 192, "hidden_channels": 192, "gin_channels": 512,
        "upsample_rates": [8, 8, 2, 2, 2], "upsample_kernel_sizes": [16, 16, 8, 2, 2],
        "resblock_kernel_sizes": [3, 7, 11], "resblock_dilation_sizes": [[1, 3, 5]] * 3,
        "upsample_initial_channel": 512, "resblock": "1"}
    if not str(config.get("version", "")).endswith("JP-Extra") or data.get("sampling_rate") != 44100 or data.get("hop_length") != 512 or not data.get("add_blank", False):
        raise ValueError("Supported profile: JP-Extra, 44.1 kHz, hop 512, add_blank=true")
    for name, value in expected.items():
        # AIVM exporters omit defaults (notably upsample_initial_channel).
        # These are the defaults in the pinned upstream HyperParameters.Model.
        if model.get(name, value) != value: raise ValueError(f"Unsupported architecture: {name}={model.get(name)!r}; expected {value!r}")
    values = np.load(styles, allow_pickle=False)
    if values.ndim != 2 or values.shape[1] != 256 or not np.isfinite(values).all(): raise ValueError("Invalid style vectors")
    for key, limit in [("style2id", len(values)), ("spk2id", data["n_speakers"])]:
        mapping = data.get(key)
        if not isinstance(mapping, dict) or not mapping or any(not isinstance(i, int) or not 0 <= i < limit for i in mapping.values()):
            raise ValueError(f"Invalid {key}")
    return config
