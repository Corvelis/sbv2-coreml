[日本語](compression.ja.md)

# Reduce the shared model size

`compress-common` compresses the BERT weights in a downloaded common model and writes a new folder.
Keep using your separate voice model. No retraining or original BERT checkpoint is required.
Use macOS and the converter's `convert` dependencies; see [conversion](conversion.md) for installation.

Prebuilt INT8 and original FP32 models do not require conversion. See [model selection](model-selection.md) for downloads, trade-offs and switching.
To create your own variants, download the original FP32 version:

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "float32/*" --local-dir models
```

## Size and speed

The shared BERT/dictionary is approximately 1.52 GB in FP32, 503 MB in 8bit, or 815 MB with FP16 weight storage.
With the separate JVNV voice, totals are approximately 1.81 GB, 797 MB, and 1.11 GB. Runtime compilation caches are additional.

For three sentences with JVNV Neutral on iPhone 17 Pro, the warmed median RTF was 0.067 for FP32 and 0.071 for 8bit.
Other voices, texts and devices can differ; these measurements did not run an LLM concurrently.
The first BERT prediction takes longer with 8bit storage in SDK v0.2.0. Cached reload plus `warmUp` took approximately 6 seconds for FP32 and 18 seconds for 8bit in this comparison.
Initial compilation is an additional cost. Retain a prepared synthesizer for repeated use.

## Compress the original model

```sh
.venv/bin/sbv2-coreml compress-common \
  --input models/float32 \
  --output models/my-common-int8 \
  --mode int8
.venv/bin/sbv2-coreml verify models/my-common-int8
```

The `int8` mode stores weights with symmetric 8bit quantization in blocks of 32 elements.
Computation and tensor interfaces remain FP32. Supply the original uncompressed common model and a new output folder.

An FP16 weight-storage model is not distributed; you can create one with `--mode fp16-weights` for smaller numerical differences. This stores large weights in FP16 and casts them back to FP32 for computation.
It uses more storage than the 8bit option and can change runtime speed.

In the sample app's **モデル設定 → 共通モデル**, select the new shared root folder. Its dictionary is detected automatically.
For the SDK, set `ModelPaths.bert` and `ModelPaths.dictionary` to its subfolders and retain your voice folder.

Rounding BERT weights can change pronunciation, timing and waveform even when voice weights are unchanged.
Compare audio with your own voices and texts and benchmark your target devices before adoption.
Checksum verification does not evaluate perceptual quality.

The output preserves licenses, attribution and source model cards and includes compression metadata and new `checksums.json` / `download.json` files.
Original model terms still apply. Compiled `.mlmodelc` caches are excluded; initial compilation and runtime cache storage are additional costs.
