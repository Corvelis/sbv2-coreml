# Verification — 2026-09-28/29

[日本語](verification.ja.md) · [Documentation index](README.ja.md)

This is a **pre-release**. The figures below belong to this sample voice and precision
profile. They are not a guarantee for every voice, text, temperature, or concurrent LLM.

## Redesigned sample and complete-utterance playback — 2026-10-04

The sample now awaits complete `synthesize` output and plays one Float32 buffer.
It does not synthesize future segments during playback or replenish a two-second queue.
The main screen focuses on text, voice/style and generation; folders, downloads and licenses
are in model settings. It supports replay without synthesis, progress, timing metrics and stop.

The production `DemoState` and `AudioPlayer` were exercised directly in the app without
mirroring or UI automation. Mac and iPhone 17 Pro both completed 10 cases (all seven JVNV
styles, short text, multiple sentences and a long sentence), replay and stop. Every recorded
playback start followed full synthesis completion, and the audio player's completion callback
was received. The Mac main screen and settings were also inspected and operated through the UI.

Raw results: [Mac](verification/macos-sample-full-playback-20261004.json) and
[iPhone](verification/iphone-sample-full-playback-20261004.json). iPhone single-sentence RTFs
were approximately 0.096–0.106; the long sentence measured 0.070. These are individual
observations, not controlled benchmarks or universal performance guarantees. No ASR/LLM
was included. Playback completion does not establish perceptual audio quality. Hosted HF
installation remains pending. The completed listening review is recorded below.

## Physical iPhone UI operation — 2026-10-04

The current sample was operated with Apple XCUITest on iPhone 17 Pro, iOS 27.0.1
(24A446), without mirroring or locking. Two independent tests passed with zero failures:

- Default Documents model detection, preparation, Japanese text input, Neutral and Happy
  synthesis/playback completion, replay, stop, replay completion and regeneration after editing.
- Manual common-folder selection, BERT/dictionary recognition, separate voice-folder selection,
  and completed preparation/warm-up from those selected paths.

Model rows now use `contentShape` to accept taps in their empty space. An explicit
`Info-iOS.plist` fixes file sharing: `UIFileSharingEnabled` was missing from the generated
app despite the build setting. The key is now present in the built Release app. Both
distributed Xcode targets also passed Release builds.

See the [UI report](verification/iphone-sample-xcuitest-20261004.json),
[prepared screen](verification/iphone-sample-prepared-20261004.png),
[playback screen](verification/iphone-sample-playback-20261004.png) and
[settings screen](verification/iphone-sample-model-settings-20261004.png).
These app screenshots were visually inspected. Private Files listings are excluded.
Earlier automated folder navigation attempts failed; navigation through the parent-folder
menu completed the manual-selection test. These checks are not statistical speed measurements
or subjective listening evaluations.

## Natural utterances versus original voice weights — 2026-10-04

The shipped JVNV F1 JP-Extra voice was compared with FP32 PyTorch loaded from the
original Safetensors. Eleven cases / seventeen segments cover all seven styles,
long vowels, multiple sentences, a long sentence split at model capacity, and a short greeting.
The production SDK's phonemes, BERT features and actual random tensors were captured
with seed `20261004` and passed to the original voice network. This isolates voice
conversion: the original frontend and BERT were not independently rerun.

Every phoneme duration and output sample count matched. Whole-case SNR was
46.05–47.01 dB; maximum absolute error was below 0.002573 and correlation exceeded
0.999988. Final 13-frame errors are also recorded. All cases passed the mixed-precision
numerical bounds (SNR at least 35 dB, maximum absolute error at most 0.05).
See the [natural voice report](verification/jvnv-natural-voice-20261004.json).

Original/Core ML WAV pairs without loudness normalization were prepared locally.
On 2026-10-04 the user reported listening through the complete comparison set and
judged it acceptable, while reporting extremely rare noise. No case, timestamp or
original/Core ML variant was identified for that noise. This completes the listening
review with that qualification; it is not a finding of zero noise or perceptual identity.
Concurrent Irodori inference and compilation exclude this run from speed evaluation.

## Historical sample UI verification before redesign — 2026-10-04

This records the previous UI and playback implementation. See the section above for the current sample.

The Mac Release sample was operated through its UI: model-folder selection, automatic
common BERT/dictionary recognition, preparation/warm-up, short and multi-sentence synthesis,
playback-queue completion, and all seven JVNV styles. Stopping and restarting long speech
also worked. Cold preparation displayed 31.6 seconds; after restarting with compiled caches,
preparation displayed 7.6 seconds. These are individual UI observations, not a controlled benchmark.

The sample displayed stale playback time after completion or stopping. Its status messages
were corrected and verified on Mac. No inference code or model weights changed. Both Release
targets built successfully; the updated iPhone sample was installed and launched on iPhone 17 Pro.

iPhone UI operation was pending at that point because mirroring required the phone to be locked.
The current UI was subsequently checked with XCUITest as recorded above.
Hosted Hugging Face download checks and listening comparisons were also pending at that
point. The current listening verdict is recorded above. Playback-queue completion itself
does not establish perceptual voice quality.
Individual observations and remaining checks are recorded in the
[UI verification report](verification/sdk-ui-20261004.json).

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
quantization, or voice-weight substitution was used. The eleven-case natural-text comparison
set was reviewed by the user, who judged it acceptable with extremely rare noise.
Generated comparison WAVs are retained locally with that verdict.

## Before a stable public release

1. Choose the GitHub/Hugging Face owner/repository names; add immutable download links.
2. Exercise the HTTPS downloader against those actual hosted manifests on a clean device.

Downstream applications also need deployment/signing and license review for their intended use.

Long-running thermal behavior, concurrent ASR/LLM scheduling, other voices/speakers and all
supported OS versions are outside this standalone release's measurements. They should not
be inferred from earlier Local AI benchmarks with different voices.
