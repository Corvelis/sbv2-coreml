"""Reject incomplete checkpoints instead of exporting randomly initialized layers."""
from safetensors import safe_open


def validate_loaded_weights(model, checkpoint):
    import torch
    checked = 0
    with safe_open(str(checkpoint), framework="pt", device="cpu") as source:
        keys = set(source.keys())
        for name, actual in model.state_dict().items():
            # The posterior encoder is training-only and omitted by inference exports.
            if name.startswith("enc_q."):
                continue
            if name not in keys:
                raise ValueError(f"Required checkpoint tensor is missing: {name}")
            expected = source.get_tensor(name).to(dtype=actual.dtype)
            if expected.shape != actual.shape or not torch.equal(expected, actual.cpu()):
                raise ValueError(f"Loaded checkpoint tensor differs: {name}")
            if not torch.isfinite(actual).all():
                raise ValueError(f"Non-finite checkpoint tensor: {name}")
            checked += 1
    return checked
