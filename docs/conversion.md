# Conversion

Use macOS on Apple Silicon and Python 3.11. Install `converter[convert]` using the
constraints in `converter/requirements-lock-macos-arm64.txt`; run `sbv2-coreml doctor`.

## Inputs

| Input | Command options |
|---|---|
| AivisHub page | `--aivis-url https://hub.aivis-project.com/aivm-models/<UUID>` |
| Local AIVM | `--aivm voice.aivm` |
| Training output | `--checkpoint model.safetensors --config config.json --styles style_vectors.npy` |

For Safetensors, config/styles default to files beside the checkpoint. AIVM embeds them.
Hub acquisition checks architecture, the presence of original AIVM weights and the
server-provided SHA-256. It reports the model name/version/license before downloading.
`inspect-hub URL` inspects metadata without downloading weights.

The output must be a new directory; a failed conversion never replaces an existing voice.
The original inputs are read-only. The shared BERT is not an input to voice conversion.
Core ML packages and validation reports are installed only after conversion succeeds.
Expect substantial temporary disk use and CPU activity. First-run source downloads are cached.
`--cache DIR` changes the cache location; it contains downloaded source/weights, not user originals.
Temporary per-conversion models are removed automatically after success or failure.

## Source and numerical profile

`upstream.lock.json` pins the SBV2 source archive by commit and SHA-256.
`--source-root DIR` is available for offline/custom source, with Python file hashes recorded in provenance.
The supported architecture is checked before tracing. Required inference tensor shapes must
match that architecture; changing the model structure can require runtime/converter changes.

The converter exports encoder/DP, SDP, full Flow, and the upstream Decoder directly from
PyTorch. Decoder weight normalization is materialized in FP32 and checked before export.
No intermediate ONNX is required. Core ML Tools and the model implementation remain Python dependencies.
The pinned upstream eagerly imports ONNX Runtime in a utility module. Conversion uses a
temporary source copy with that optional import moved into its unused ONNX helper. The patch
is recorded in provenance; original source/weights are not modified. ONNX Runtime is not installed.

The reference path uses FP32. The fixed 256-frame and 32-frame fast decoders retain FP32 in
sensitive early/conditioning layers and use FP16 for other operations. Their historical
function names end in `_fp16`; `decoder_validation.json` specifies the actual mixed precision.
If a fixed decoder exceeds the numerical error bounds, it is re-exported in FP32 and
checked against the stricter FP32 bounds. The report records both attempts and the effective
precision; a fallback can be slower and must be measured for that voice.
There is no integer quantization or retraining. Output is not generally bit-identical to PyTorch.

Validation checks:

- Individual pre/SDP/Flow comparisons and the SDP spline rewrite.
- FP32 waveform SNR >= 60 dB and max absolute error <= 0.001 on fixed synthetic inputs.
- Fixed decoder sanity bounds (SNR >= 35 dB and max error <= 0.05), with actual errors retained.
  These bounds detect conversion failures; they are not a perceptual quality guarantee.
- Exact CPU output equality before/after combining functions into a shared-weight package.

Listen to your own voices and compare natural-text output before publishing. Fast execution
also needs device validation; Core ML CPU/GPU/ANE scheduling is platform dependent.
Checkpoint source, config, styles, converter version and model files are fingerprinted.

## Licenses and packaging

For a self-trained model, specify its actual redistribution terms and source attribution:

```sh
sbv2-coreml convert --checkpoint model.safetensors --output models/my-voice \
  --license-file LICENSE.md --license-id cc-by-sa-4.0 --source-url https://example.org/my-model
sbv2-coreml verify models/my-voice
sbv2-coreml package --input models/my-voice --output artifacts/my-voice.tar.gz
```

The license ID above is an example, not a license automatically granted to every input.
AIVM license text is preserved automatically when present. For custom/ACML licenses use
`--license-id other` and publish the exact text and terms. Redistribution packaging refuses
missing license/provenance; local private conversion can complete without a redistribution license.

## Rebuild the common BERT

Acquire `ku-nlp/deberta-v2-large-japanese-char-wwm` at revision
`547b0e8b044fba3f9b84d0ab9f990440bd130c8b`, including `config.json`,
`model.safetensors` and `vocab.txt`, then run:

```sh
sbv2-coreml build-bert --checkpoint-dir /path/to/checkpoint --output models/bert
```

This reproduces the two-block FP32 layout with shapes 64/128/256. It is separate from
voice conversion because the shared BERT does not change when replacing a compatible voice.
The release preparation script adds model cards, dictionary, license, provenance and checksums.
