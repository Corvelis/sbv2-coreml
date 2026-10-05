# SBV2 Core ML

[日本語](README.md)

Japanese Style-Bert-VITS2 JP-Extra speech synthesis for iPhone and Apple Silicon Mac.
Includes a Swift SDK, native sample apps, a WAV CLI and a voice-model converter.
Inference runs on-device through Core ML. Python and ONNX Runtime are not required in your app.

## Requirements

- iOS 18+ or macOS 15+ on Apple Silicon.
- Xcode to build the SDK or sample app.
- Both the [shared BERT/dictionary](https://huggingface.co/AILogDev/sbv2-coreml-common)
  and the [JVNV voice](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp).
  Model weights are downloaded separately from the source/SDK.

[Source downloads](https://github.com/Corvelis/sbv2-coreml) ·
[Quick Start](docs/getting-started.ja.md) · [SDK guide](docs/sdk-guide.ja.md) ·
[Sample app](docs/sample-app.ja.md) · [API reference](docs/api-reference.ja.md) ·
[Troubleshooting](docs/troubleshooting.ja.md)

## Add the SDK

In Xcode, select **File → Add Package Dependencies**, enter
`https://github.com/Corvelis/sbv2-coreml.git`, choose **Exact Version: 0.1.0-dev5**,
and add the **SBV2CoreML** product to your app.

```swift
import Foundation
import SBV2CoreML

// JVNV: speaker 0, Neutral style.
func renderSample(common: URL, voice: URL) async throws -> Data {
    let speech = SpeechSynthesizer()
    try await speech.load(ModelPaths(
        bert: common.appendingPathComponent("bert"),
        voice: voice,
        dictionary: common.appendingPathComponent("dictionary")))
    try await speech.warmUp()
    let audio = try await speech.synthesize("こんにちは。お元気ですか？")
    let wav = try audio.wav()
    try await speech.unload()
    return wav
}
```

Pass the downloaded shared and voice folder URLs. Retain one synthesizer and call
`load`/`warmUp` once when preparing an app for repeated utterances.
The SDK returns PCM; your app handles playback. The sample demonstrates AVAudioEngine playback,
replay and cancellation. See the [SDK guide](docs/sdk-guide.ja.md).

## Run the sample

Open `Examples/Apple/SBV2Demo.xcodeproj` in Xcode. Select `SBV2Demo-iOS` or
`SBV2Demo-macOS`; for iPhone, set your signing team and a unique bundle identifier.
In **モデル設定 → URLからモデルを取得**, select INT8/FP32 under **共通モデルの版** to fill the manifest URL automatically.
Download your shared model and voice, or choose existing folders. Press **モデルを準備**,
then enter Japanese text and press **生成して再生**.
The app generates the complete utterance before playing it.

## Create a WAV on Mac

Download one shared variant and a voice into `models/` as shown in the [model selection guide](docs/model-selection.md).
The example uses INT8; replace `int8` with `float32` for FP32, then run from the source root:

```sh
swift run -c release sbv2-say \
  models/int8/bert \
  models/sbv2-coreml-jvnv-f1-jp \
  models/int8/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
afplay output.wav
```

You can append `STYLE SPEAKER_ID`, for example `Happy 0`.
Models compile on first use. Keep the compiled caches for faster subsequent loads.

## Convert another voice

Use Apple Silicon macOS and Python 3.11:

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt
.venv/bin/sbv2-coreml convert --aivm voice.aivm --output models/my-voice
```

Supported inputs: AivisHub URLs, AIVM, or Safetensors with config/style vectors.
Compatible voices reuse the shared BERT/dictionary.
ONNX/AIVMX-only inputs, standard SBV2 and multilingual profiles are not supported.
[Conversion guide](docs/conversion.md) · [Model format](docs/model-format.md)

## Choose INT8 or original FP32

Both variants work with the same SDK and separate voice models.

| Variant | Shared BERT/dictionary | With JVNV | Choose when |
|---|---:|---:|---|
| INT8 (`int8/`) | About 503 MB | About 797 MB | Storage size matters |
| Original FP32 (`float32/`) | About 1.52 GB | About 1.81 GB | Avoiding weight quantization or shorter preparation matters |

INT8 changes BERT weight storage; BERT computation and tensor interfaces remain FP32.
Voice weights are unchanged, but BERT feature differences can affect prosody and audio duration.
INT8 takes longer to prepare and is not necessarily faster to synthesize.
[Download both variants, switch models and compare performance](docs/model-selection.md)

The converter also includes `compress-common` for creating your own compressed shared model. [Compression guide](docs/compression.md)

## Licenses

Code: **AGPL-3.0**. Shared BERT and JVNV voice: **CC BY-SA 4.0**.
The dictionary and other voices retain their own terms.
[Third-party notices](THIRD_PARTY_NOTICES.en.md)
