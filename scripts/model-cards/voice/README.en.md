---
license: cc-by-sa-4.0
language: ja
pipeline_tag: text-to-speech
tags: [coreml, style-bert-vits2, jp-extra]
base_model: litagin/style_bert_vits2_jvnv
---
# JVNV F1 JP-Extra for Core ML

[日本語（メイン）](README.md)

One Japanese voice for the SBV2CoreML Swift library, iOS 18+ / macOS 15+ Apple Silicon.
Common BERT and an Open JTalk dictionary are required separately.

## Attribution and changes

Original model: litagin, [Style-Bert-VITS2 JVNV](https://huggingface.co/litagin/style_bert_vits2_jvnv),
`jvnv-F1-jp/jvnv-F1-jp_e160_s14000.safetensors`, revision
`205830ca1d49e666ddfbf2a755f0108e9cade4dd`. Trained on the
[JVNV corpus](https://sites.google.com/site/shinnosuketakamichi/research-topics/jvnv_corpus).
The original and this converted model are provided under CC BY-SA 4.0 (LICENSE.md).
This is an unofficial conversion, without endorsement by the original creators.

Converted from the original weights into Core ML encoder/DP, SDP, full-sentence
Flow and Decoder functions. A multifunction package shares identical weights
across shapes. There is no retraining or integer quantization. Fast decoder
functions use mixed FP32/FP16 precision; an FP32 reference decoder is retained.
This conversion is not bit-identical to the original PyTorch waveform.

## Usage and limits

Pass this folder as the voice in `ModelPaths`. Available styles are Neutral,
Angry, Disgust, Fear, Happy, Sad and Surprise; speaker ID is 0. Output is mono
44.1 kHz. Sentence segmentation and model capacity limits are handled by the
Swift library. Only compatible Japanese JP-Extra models are supported.

The sample can import this folder, or download `download.json` from a pinned
Hugging Face revision. All files have hashes. It compiles the model on first use.

## Validation

`waveform_validation.json` compares the FP32 full neural chain with PyTorch on
fixed synthetic inputs. `decoder_validation.json` reports FP32 and mixed precision
errors separately. `compaction_report.json` checks exact equality before/after
multifunction packaging. These tests do not establish identical voice quality
for every sentence. See the source release's verification report for native
device measurements and their scope; RTF 0.1 is not a universal guarantee.

The 2026-10-04 review of 0.1.0-dev1 covered eleven natural-text cases including
all seven styles. Whole-case SNR against the original FP32 voice was 46.05-47.01 dB,
with identical phoneme durations and sample counts; frontend/BERT features and noise
were shared for that comparison. The user listened through the comparison set and
judged it acceptable, while reporting extremely rare noise. The affected case and
original/Core ML variant were not identified. This is not a finding of zero noise.
See the source release's verification report for the complete scope and results.

The code and weights have separate licenses. The source release is AGPL-3.0.
