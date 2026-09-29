# Verification — 2026-09-28/29

[日本語](verification.ja.md) · [Documentation index](README.ja.md)

This is a **pre-release**. The figures below belong to this sample voice and precision
profile. They are not a guarantee for every voice, text, temperature, or concurrent LLM.

## Build and integration

- Swift Package release build and 7 unit tests: passed.
- iPhone and Apple Silicon Mac example applications: Release builds passed.
- Python package: normal wheel installation and CLI entry point passed in Python 3.11.9.
- Original JVNV Safetensors → voice package: passed full waveform and compaction checks.
- A local AivisHub AIVM (Kanon) → voice package: passed, including embedded configuration,
  styles and license. Tested with ONNX and ONNX Runtime absent from the Python environment.
  This second model is a private conversion test and is not bundled with the release.
- AivisHub metadata inspection: exercised against the official API. AIVMX-only inputs
  are rejected before download. Original-weight download uses the API-provided SHA-256.
- Shared BERT: reused the existing converted FP32 blocks and verified native inference
  on both devices. The `build-bert` wrapper's portable output handling is tested; a fresh
  full BERT rebuild through that wrapper has not been repeated for this preparation.

## Native performance

Release build, JVNV F1 JP-Extra, shared FP32 DeBERTa, mixed FP32/FP16 fixed decoders,
seed `20260928`. The native runtime requests CPU + Neural Engine for voice models;
that setting does not establish that every operator runs on ANE. No playback, microphone,
ASR or LLM is included. Thermal state was **fair** (`1`) during these runs.

| Case | Audio duration | iPhone 17 Pro RTF | Apple M2 Mac / 24 GB RTF |
|---|---:|---:|---:|
| Normal sentence, first warm run | 3.332 s | 0.105 | 0.177 |
| Same sentence, next run | 3.297 s | 0.090 | 0.146 |
| Two sentences | 3.170 s | 0.111 | 0.206 |
| Happy style | 2.299 s | 0.140 | 0.208 |

These are individual smoke-test observations, not statistical benchmark medians.
Mac compilation/conversion work was also active; this is not an isolated performance comparison.
No model capacity splitting occurred for these inputs. Original reports:
[iPhone](verification/iphone-smoke.json), [Mac](verification/macos-smoke.json).
OS versions are recorded there; minimum advertised OS versions are build targets,
not a claim that every supported OS/device was physically tested.

Cold model preparation took **18.99 s** on iPhone and **25.79 s** on Mac. The first
0.824 s greeting then took **7.50 s** and **10.39 s**, respectively, including first-use
specialization. The app's **準備・ウォームアップ** step performs an initial synthesis before
interactive use. A new input shape can still incur first-use costs. Retain compiled caches.

## Numerical checks

JVNV, fixed synthetic phonemes/BERT features/noise:

- Full FP32 neural waveform vs original PyTorch: **94.80 dB SNR**, maximum absolute
  difference **0.000006294**.
- Fixed mixed precision decoder vs PyTorch, CPU: approximately **36.9 dB SNR** for the
  256- and 32-frame checks. FP32 decoder: over 111 dB on the tested lengths.
- Combining shape variants into one multifunction package: **all tested CPU outputs
  bit-identical** before/after compaction. Model package reduced from 899.8 MB to 293.6 MB.
- Decoder windows, 13-frame context and final-tail correction: 10 checks across lengths
  16/31/64/236/512, using CPU and CPU+ANE settings on Mac; minimum whole-output SNR
  **36.85 dB** vs the full FP32 decoder. Boundary errors are recorded separately in the
  [window report](verification/jvnv-decoder-windows.json). No whole-sentence Flow splitting.

Kanon's mixed precision decoder exceeded the 35 dB sanity bound on the test input.
The converter automatically re-exported both fixed decoder functions as FP32 and verified
them at the stricter FP32 bounds. Its FP32 full waveform measured **102.95 dB SNR**.
This fallback prioritizes numerical fidelity and may be slower; no speed claim is made
for the resulting Kanon conversion. Effective precision is written into model metadata.

The checks do not certify identical perceived voice quality. No training, integer
quantization, or voice-weight substitution was used. A release review should listen to
natural text across the intended styles/speakers, especially long vowels, silence, joins
and sentence endings. Generated iPhone/Mac WAVs are retained locally for that review.

## Before a stable public release

1. Listen to the natural-text samples and compare the intended voice with its original.
2. Choose the GitHub/Hugging Face owner/repository names; add immutable download links.
3. Exercise the HTTPS downloader against those actual hosted manifests on a clean device.
4. Confirm deployment/signing and license obligations for the intended downstream use.

Long-running thermal behavior, concurrent ASR/LLM scheduling, all styles/speakers and all
supported OS versions are outside this standalone release's measurements. They should not
be inferred from earlier Local AI benchmarks with different voices.
