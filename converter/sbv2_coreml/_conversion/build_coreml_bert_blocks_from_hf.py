#!/usr/bin/env python3
"""Build Core ML BERT blocks from a Hugging Face DeBERTa checkpoint.

This script is intentionally BERT-specific. It does not assume decoder-side
conversion code can be reused. Each exported block is defined in semantic
DeBERTa terms so iOS runtime work can be built around stable block contracts
instead of fragile ONNX-optimized tensor names.
"""

from __future__ import annotations

import argparse
import json
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import coremltools as ct
import torch
from transformers import AutoConfig, AutoModel
from transformers.models.deberta_v2 import modeling_deberta_v2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "model_source",
        help="HuggingFace model id or local checkpoint directory.",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--block",
        action="append",
        required=True,
        help="Block to export. Examples: embeddings, encoder_conv, layer.1/attention, layer.0/intermediate, layer.1/output",
    )
    parser.add_argument("--seq-len-min", type=int, default=2)
    parser.add_argument("--seq-len-max", type=int, default=256)
    parser.add_argument("--seq-len-example", type=int, default=32)
    parser.add_argument(
        "--seq-len-candidates",
        default="",
        help="Comma-separated fixed sequence lengths for one EnumeratedShapes model.",
    )
    parser.add_argument("--local-files-only", action="store_true")
    parser.add_argument("--trust-remote-code", action="store_true")
    parser.add_argument("--append-manifest", action="store_true")
    parser.add_argument(
        "--compute-precision",
        choices=("float16", "float32"),
        default="float32",
        help="Core ML internal precision; float32 favors numerical agreement with PyTorch.",
    )
    return parser.parse_args()


def patch_deberta_for_coreml() -> None:
    def scaled_size_sqrt_coreml(query_layer: torch.Tensor, scale_factor: int) -> torch.Tensor:
        scale_value = float(query_layer.shape[-1] * scale_factor) ** 0.5
        return torch.tensor(scale_value, dtype=query_layer.dtype, device=query_layer.device)

    def build_relative_position_coreml(
        query_layer: torch.Tensor,
        key_layer: torch.Tensor,
        bucket_size: int = -1,
        max_position: int = -1,
    ) -> torch.Tensor:
        query_size = query_layer.size(-2)
        key_size = key_layer.size(-2)
        q_ids = torch.arange(query_size, dtype=torch.long, device=query_layer.device)
        k_ids = torch.arange(key_size, dtype=torch.long, device=key_layer.device)
        rel_pos_ids = q_ids[:, None] - k_ids[None, :]
        if bucket_size > 0 and max_position > 0:
            rel_pos_ids = modeling_deberta_v2.make_log_bucket_position(rel_pos_ids, bucket_size, max_position)
        rel_pos_ids = rel_pos_ids.to(torch.long)
        rel_pos_ids = rel_pos_ids[:query_size, :]
        return rel_pos_ids.unsqueeze(0).unsqueeze(0)

    def build_rpos_coreml(
        query_layer: torch.Tensor,
        key_layer: torch.Tensor,
        relative_pos: torch.Tensor,
        position_buckets: int,
        max_relative_positions: int,
    ) -> torch.Tensor:
        if key_layer.size(-2) != query_layer.size(-2):
            return build_relative_position_coreml(
                key_layer,
                key_layer,
                bucket_size=position_buckets,
                max_position=max_relative_positions,
            )
        if relative_pos.dim() == 2:
            return relative_pos.unsqueeze(0).unsqueeze(0)
        if relative_pos.dim() == 3:
            return relative_pos.unsqueeze(1)
        return relative_pos

    modeling_deberta_v2.scaled_size_sqrt = scaled_size_sqrt_coreml
    modeling_deberta_v2.build_relative_position = build_relative_position_coreml
    modeling_deberta_v2.build_rpos = build_rpos_coreml


@dataclass
class BlockSpec:
    name: str
    input_names: list[str]
    output_names: list[str]
    example_inputs: tuple[torch.Tensor, ...]
    range_shapes: list[object]


class EmbeddingsBlock(torch.nn.Module):
    def __init__(self, embeddings: torch.nn.Module) -> None:
        super().__init__()
        self.embeddings = embeddings

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        return self.embeddings(input_ids=input_ids, mask=attention_mask).to(torch.float32)


class PrefixBlock(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.embeddings = model.embeddings
        self.encoder = model.encoder

    def forward(
        self, input_ids: torch.Tensor, attention_mask: torch.Tensor
    ) -> tuple[torch.Tensor, torch.Tensor]:
        embeddings = self.embeddings(input_ids=input_ids, mask=attention_mask)
        relative_embeddings = self.encoder.get_rel_embedding()
        relative_pos = self.encoder.get_rel_pos(embeddings, None, None)
        expanded_mask = self.encoder.get_attention_mask(attention_mask)
        layer0, _ = self.encoder.layer[0](
            embeddings,
            expanded_mask,
            query_states=None,
            relative_pos=relative_pos,
            rel_embeddings=relative_embeddings,
            output_attentions=False,
        )
        return layer0.to(torch.float32), embeddings.to(torch.float32)


class EncoderConvBlock(torch.nn.Module):
    def __init__(self, conv: torch.nn.Module) -> None:
        super().__init__()
        self.conv = conv

    def forward(
        self,
        hidden_states: torch.Tensor,
        residual_states: torch.Tensor,
        attention_mask: torch.Tensor,
    ) -> torch.Tensor:
        return self.conv(hidden_states, residual_states, attention_mask).to(torch.float32)


class LayerAttentionBlock(torch.nn.Module):
    def __init__(self, encoder: torch.nn.Module, layer_index: int) -> None:
        super().__init__()
        self.encoder = encoder
        self.layer_index = layer_index

    def forward(self, hidden_states: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        rel_embeddings = self.encoder.get_rel_embedding()
        relative_pos = self.encoder.get_rel_pos(hidden_states, None, None)
        expanded_mask = self.encoder.get_attention_mask(attention_mask)
        attention_output, _ = self.encoder.layer[self.layer_index].attention(
            hidden_states,
            expanded_mask,
            output_attentions=False,
            query_states=None,
            relative_pos=relative_pos,
            rel_embeddings=rel_embeddings,
        )
        return attention_output.to(torch.float32)


class LayerIntermediateBlock(torch.nn.Module):
    def __init__(self, encoder: torch.nn.Module, layer_index: int) -> None:
        super().__init__()
        self.layer = encoder.layer[layer_index]

    def forward(self, hidden_states: torch.Tensor) -> torch.Tensor:
        return self.layer.intermediate(hidden_states).to(torch.float32)


class LayerOutputBlock(torch.nn.Module):
    def __init__(self, encoder: torch.nn.Module, layer_index: int) -> None:
        super().__init__()
        self.layer = encoder.layer[layer_index]

    def forward(self, intermediate_states: torch.Tensor, attention_states: torch.Tensor) -> torch.Tensor:
        return self.layer.output(intermediate_states, attention_states).to(torch.float32)


class LayerRangeBlock(torch.nn.Module):
    def __init__(self, encoder: torch.nn.Module, start_layer: int, end_layer: int) -> None:
        super().__init__()
        self.encoder = encoder
        self.start_layer = start_layer
        self.end_layer = end_layer

    def forward(self, hidden_states: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        rel_embeddings = self.encoder.get_rel_embedding()
        relative_pos = self.encoder.get_rel_pos(hidden_states, None, None)
        expanded_mask = self.encoder.get_attention_mask(attention_mask)
        output = hidden_states
        for layer_index in range(self.start_layer, self.end_layer + 1):
            output, _ = self.encoder.layer[layer_index](
                output,
                expanded_mask,
                query_states=None,
                relative_pos=relative_pos,
                rel_embeddings=rel_embeddings,
                output_attentions=False,
            )
        return output.to(torch.float32)


class LayerRangeWithConvBlock(torch.nn.Module):
    def __init__(self, encoder: torch.nn.Module, start_layer: int, end_layer: int) -> None:
        super().__init__()
        self.encoder = encoder
        self.layer_range = LayerRangeBlock(encoder, start_layer, end_layer)

    def forward(
        self,
        layer0_states: torch.Tensor,
        embeddings_states: torch.Tensor,
        attention_mask: torch.Tensor,
    ) -> torch.Tensor:
        # DeBERTa applies its convolution after layer 0, using embeddings as
        # the first argument and layer 0 output as the residual argument.
        after_conv = self.encoder.conv(embeddings_states, layer0_states, attention_mask)
        return self.layer_range(after_conv, attention_mask)


def load_model(args: argparse.Namespace) -> tuple[torch.nn.Module, dict[str, Any]]:
    patch_deberta_for_coreml()
    config = AutoConfig.from_pretrained(
        args.model_source,
        local_files_only=args.local_files_only,
        trust_remote_code=args.trust_remote_code,
    )
    model = AutoModel.from_pretrained(
        args.model_source,
        local_files_only=args.local_files_only,
        trust_remote_code=args.trust_remote_code,
    )
    model.eval()
    model.warn_if_padding_and_no_attention_mask = lambda *args, **kwargs: None
    summary = {
        "model_type": getattr(config, "model_type", None),
        "hidden_size": getattr(config, "hidden_size", None),
        "num_hidden_layers": getattr(config, "num_hidden_layers", None),
        "num_attention_heads": getattr(config, "num_attention_heads", None),
        "vocab_size": getattr(config, "vocab_size", None),
    }
    return model, summary


def parse_layer_block(block_name: str) -> tuple[int, str] | None:
    if not block_name.startswith("layer."):
        return None
    head, sep, tail = block_name.partition("/")
    if not sep:
        return None
    layer_text = head.split(".", 1)[1]
    if not layer_text.isdigit():
        return None
    return int(layer_text), tail


def parse_layer_group_block(block_name: str) -> tuple[int, int] | None:
    if not block_name.startswith("group."):
        return None
    range_text = block_name.split(".", 1)[1]
    start_text, sep, end_text = range_text.partition("-")
    if not sep or not start_text.isdigit() or not end_text.isdigit():
        return None
    return int(start_text), int(end_text)


def build_block_module(
    model: torch.nn.Module,
    block_name: str,
    seq_len: int,
    seq_len_min: int,
    seq_len_max: int,
    seq_len_candidates: list[int] | None = None,
) -> tuple[torch.nn.Module, BlockSpec]:
    hidden_size = int(model.config.hidden_size)
    batch = 1
    seq_range: int | ct.RangeDim = (
        seq_len_min if seq_len_min == seq_len_max else ct.RangeDim(seq_len_min, seq_len_max)
    )
    def shape(*tail: int) -> object:
        if seq_len_candidates:
            return ct.EnumeratedShapes(
                shapes=[[batch, candidate, *tail] for candidate in seq_len_candidates],
                default=[batch, seq_len_candidates[0], *tail],
            )
        return [batch, seq_range, *tail]
    if block_name == "group.1-23-conv":
        module = LayerRangeWithConvBlock(model.encoder, 1, 23).eval()
        example_inputs = (
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.ones((batch, seq_len), dtype=torch.float32),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["layer0_states", "embeddings_states", "attention_mask"],
            output_names=["group_hidden_states"],
            example_inputs=example_inputs,
            range_shapes=[
                shape(hidden_size),
                shape(hidden_size),
                shape(),
            ],
        )
        return module, spec
    if block_name == "prefix.0":
        module = PrefixBlock(model).eval()
        example_inputs = (
            torch.zeros((batch, seq_len), dtype=torch.long),
            torch.ones((batch, seq_len), dtype=torch.long),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["input_ids", "attention_mask"],
            output_names=["layer0_states", "embeddings_states"],
            example_inputs=example_inputs,
            range_shapes=[shape(), shape()],
        )
        return module, spec
    if block_name == "embeddings":
        module = EmbeddingsBlock(model.embeddings).eval()
        example_inputs = (
            torch.zeros((batch, seq_len), dtype=torch.long),
            torch.ones((batch, seq_len), dtype=torch.long),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["input_ids", "attention_mask"],
            output_names=["hidden_states"],
            example_inputs=example_inputs,
            range_shapes=[shape(), shape()],
        )
        return module, spec

    if block_name == "encoder_conv":
        if getattr(model.encoder, "conv", None) is None:
            raise SystemExit("encoder conv is not present in this checkpoint")
        module = EncoderConvBlock(model.encoder.conv).eval()
        example_inputs = (
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.ones((batch, seq_len), dtype=torch.float32),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["hidden_states", "residual_states", "attention_mask"],
            output_names=["conv_hidden_states"],
            example_inputs=example_inputs,
            range_shapes=[
                shape(hidden_size),
                shape(hidden_size),
                shape(),
            ],
        )
        return module, spec

    parsed_group = parse_layer_group_block(block_name)
    if parsed_group is not None:
        start_layer, end_layer = parsed_group
        if start_layer > end_layer:
            raise SystemExit(f"invalid layer group: {block_name}")
        if start_layer < 0 or end_layer >= len(model.encoder.layer):
            raise SystemExit(f"layer group out of range: {block_name}")
        module = LayerRangeBlock(model.encoder, start_layer, end_layer).eval()
        example_inputs = (
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.ones((batch, seq_len), dtype=torch.long),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["hidden_states", "attention_mask"],
            output_names=["group_hidden_states"],
            example_inputs=example_inputs,
            range_shapes=[
                shape(hidden_size),
                shape(),
            ],
        )
        return module, spec

    parsed = parse_layer_block(block_name)
    if parsed is None:
        raise SystemExit(f"unsupported block: {block_name}")
    layer_index, layer_part = parsed
    if layer_index >= len(model.encoder.layer):
        raise SystemExit(f"layer index out of range: {layer_index}")

    if layer_part == "attention":
        module = LayerAttentionBlock(model.encoder, layer_index).eval()
        example_inputs = (
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
            torch.ones((batch, seq_len), dtype=torch.long),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["hidden_states", "attention_mask"],
            output_names=["attention_states"],
            example_inputs=example_inputs,
            range_shapes=[
                shape(hidden_size),
                shape(),
            ],
        )
        return module, spec

    if layer_part == "intermediate":
        module = LayerIntermediateBlock(model.encoder, layer_index).eval()
        example_inputs = (torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),)
        spec = BlockSpec(
            name=block_name,
            input_names=["hidden_states"],
            output_names=["intermediate_states"],
            example_inputs=example_inputs,
            range_shapes=[shape(hidden_size)],
        )
        return module, spec

    if layer_part == "output":
        intermediate_size = int(model.config.intermediate_size)
        module = LayerOutputBlock(model.encoder, layer_index).eval()
        example_inputs = (
            torch.zeros((batch, seq_len, intermediate_size), dtype=torch.float32),
            torch.zeros((batch, seq_len, hidden_size), dtype=torch.float32),
        )
        spec = BlockSpec(
            name=block_name,
            input_names=["intermediate_states", "attention_states"],
            output_names=["hidden_states"],
            example_inputs=example_inputs,
            range_shapes=[
                shape(intermediate_size),
                shape(hidden_size),
            ],
        )
        return module, spec

    raise SystemExit(f"unsupported layer block part: {layer_part}")


def export_block_coreml(
    module: torch.nn.Module,
    spec: BlockSpec,
    output_dir: Path,
    compute_precision: str,
    enumerated_shapes: bool = False,
) -> dict[str, Any]:
    package_name = spec.name.replace("/", "__") + (
        "_enum.mlpackage" if enumerated_shapes else "_flex.mlpackage"
    )
    package_dir = output_dir / package_name
    if package_dir.exists():
        shutil.rmtree(package_dir)

    with torch.no_grad():
        traced = torch.jit.trace(module, spec.example_inputs)

    mlmodel = ct.convert(
        traced,
        source="pytorch",
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18 if enumerated_shapes else ct.target.iOS16,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=(
            ct.precision.FLOAT32 if compute_precision == "float32" else ct.precision.FLOAT16
        ),
        inputs=[
            ct.TensorType(name=input_name, shape=shape)
            for input_name, shape in zip(spec.input_names, spec.range_shapes, strict=True)
        ],
        outputs=[ct.TensorType(name=name) for name in spec.output_names],
        package_dir=str(package_dir),
    )
    model_spec = mlmodel.get_spec()
    print(f"wrote {package_dir}")
    return {
        "block": spec.name,
        "mlpackage": str(package_dir),
        "coreml_input_names": [item.name for item in model_spec.description.input],
        "coreml_output_names": [item.name for item in model_spec.description.output],
        "semantic_input_names": spec.input_names,
        "semantic_output_names": spec.output_names,
        "compute_precision": compute_precision,
        "minimum_deployment_target": "iOS18" if enumerated_shapes else "iOS16",
    }


def main() -> int:
    args = parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)
    candidates = [int(value) for value in args.seq_len_candidates.split(",") if value.strip()]
    if candidates and (sorted(set(candidates)) != candidates or args.seq_len_example not in candidates):
        raise SystemExit("--seq-len-candidates must be sorted, unique, and include --seq-len-example")
    if not (args.seq_len_min <= args.seq_len_example <= args.seq_len_max):
        raise SystemExit("--seq-len-example must be within [--seq-len-min, --seq-len-max]")

    model, model_summary = load_model(args)
    blocks: list[dict[str, Any]] = []
    for block_name in args.block:
        module, spec = build_block_module(
            model,
            block_name,
            args.seq_len_example,
            args.seq_len_min,
            args.seq_len_max,
            candidates,
        )
        record = export_block_coreml(module, spec, args.output_dir, args.compute_precision, bool(candidates))
        if candidates:
            record["sequence_length_candidates"] = candidates
        record["sequence_length_range"] = {
            "min": args.seq_len_min,
            "max": args.seq_len_max,
        }
        blocks.append(record)

    manifest = {
        "model_source": args.model_source,
        "model_summary": model_summary,
        "sequence_length_range": {
            "min": args.seq_len_min,
            "max": args.seq_len_max,
            "example": args.seq_len_example,
        },
        "blocks": blocks,
    }
    manifest_path = args.output_dir / "coreml_bert_blocks_manifest.json"
    if args.append_manifest and manifest_path.exists():
        existing = json.loads(manifest_path.read_text(encoding="utf-8"))
        merged_blocks: dict[str, dict[str, Any]] = {}
        for record in existing.get("blocks", []):
            if isinstance(record, dict) and isinstance(record.get("block"), str):
                merged_blocks[record["block"]] = record
        for record in blocks:
            merged_blocks[record["block"]] = record
        manifest["blocks"] = [
            merged_blocks[key]
            for key in sorted(
                merged_blocks,
                key=lambda item: (
                    0 if item == "embeddings" else
                    1 if item == "encoder_conv" else
                    2 if item.startswith("group.") else
                    3,
                    item,
                ),
            )
        ]
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"wrote {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
