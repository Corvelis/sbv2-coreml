---
license: cc-by-sa-4.0
language: ja
tags: [coreml, style-bert-vits2]
base_model: ku-nlp/deberta-v2-large-japanese-char-wwm
---
# SBV2 Core ML shared Japanese resources

[日本語（メイン）](README.md)

Shared BERT for the SBV2CoreML Swift library, iOS 18+ / macOS 15+ Apple Silicon.
Download once and reuse across compatible JP-Extra voices. This package also
contains the Open JTalk 1.11 UTF-8 dictionary under its separate BSD notices.

## Attribution and changes

BERT: Kyoto University NLP group, [original model](https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm),
revision `547b0e8b044fba3f9b84d0ab9f990440bd130c8b`. Converted to two FP32 Core ML
ML Programs with fixed candidate lengths 64/128/256. No retraining or quantization.
Original and converted BERT: CC BY-SA 4.0, see LICENSE.md.
Dictionary: Open JTalk / NAIST / UniDic contributors, see dictionary/COPYING.
These are unofficial conversions, without endorsement by the original authors.

## Usage

Pass `bert/` and `dictionary/` to `ModelPaths`; obtain a voice separately.
The sample app can import this entire folder as BERT and find the dictionary.
It can also download from the HTTPS URL of `download.json` at a pinned revision.
`checksums.json` records every distributed asset. Model compilation happens locally
on first use; compiled caches are not part of this upload.

Inference is offline. The SBV2CoreML application code has its own AGPL-3.0 license.
See the accompanying source release for setup and performance measurements.
