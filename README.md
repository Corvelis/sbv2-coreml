# SBV2 Core ML

Native Japanese **Style-Bert-VITS2 JP-Extra** speech synthesis for **iOS 18+** and
**macOS 15+ on Apple Silicon**. Includes a Swift Package, iPhone/Mac example apps,
a WAV command-line tool, and a checkpoint-to-Core-ML converter.

[日本語ドキュメント](docs/README.ja.md) · [Conversion](docs/conversion.md) · [Model format](docs/model-format.md)
· [Licenses](THIRD_PARTY_NOTICES.md) · [Release procedure](docs/releasing.md)

## Documentation

The complete Japanese guide includes a local-file Quick Start, SDK integration, all public
Swift APIs, troubleshooting, conversion, model format, licensing and release instructions.
English overview and technical notes remain below and in the linked English pages.

| Task | Guide |
|---|---|
| Run the sample from source and model archives | [Quick Start (日本語)](docs/getting-started.ja.md) |
| Add the SDK to an Xcode app | [SDK integration (日本語)](docs/sdk-guide.ja.md) |
| Look up methods, options and cancellation | [Swift API reference (日本語)](docs/api-reference.ja.md) |
| Diagnose loading, latency, audio gaps and storage | [Troubleshooting (日本語)](docs/troubleshooting.ja.md) |

The converted models are uploaded to Hugging Face; both repositories are currently private.
The GitHub source repository and release tag are still pending. Obtaining source alone does
not download model weights. See the [Quick Start](docs/getting-started.ja.md) for authenticated
model downloads and local model archives.

| Model package | Repository |
|---|---|
| Shared BERT and dictionary | [AILogDev/sbv2-coreml-common](https://huggingface.co/AILogDev/sbv2-coreml-common) |
| JVNV F1 JP-Extra voice | [AILogDev/sbv2-coreml-jvnv-f1-jp](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) |

Pinned revisions and upload verification are recorded in the [release guide](docs/releasing.md).

## Contents

- **Swift runtime:** Core ML BERT, encoder/DP, SDP, Flow and waveform decoder.
  Japanese text processing uses bundled Open JTalk source and a separately obtained dictionary.
  No Flutter, Python or ONNX Runtime is needed in the application.
- **Separate voices:** reuse one shared BERT/dictionary with multiple voice packages.
- **Sample playback:** generate the complete utterance, then play one Float32 buffer. Replay and cancellation are included.
- **Conversion:** input an AivisHub URL, one AIVM, or a Safetensors checkpoint with config/style vectors.
  The public conversion path exports directly from PyTorch without an intermediate ONNX file.
- **Distribution:** model checksums, provenance, license preservation and local HF upload staging.

This is a pre-release source distribution. See [verification](docs/verification.md) for the
tested models, device measurements and remaining release checks. The sample voice is JVNV F1 JP-Extra;
it requires the shared BERT and dictionary. Anonymous HTTPS installation is pending public visibility.

## Run on a Mac

With Xcode installed, and the two model folders obtained or prepared:

```sh
swift run -c release sbv2-say \
  /path/to/sbv2-coreml-common/bert \
  /path/to/sbv2-coreml-jvnv-f1-jp \
  /path/to/sbv2-coreml-common/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
```

The CLI optionally accepts `STYLE SPEAKER_ID` after the text. Models compile on first use.
Allow extra time and disk space for the initial compilation. Retain the resulting caches for faster reopening.

## iPhone / Mac apps

Open `Examples/Apple/SBV2Demo.xcodeproj`:

1. Choose `SBV2Demo-iOS` or `SBV2Demo-macOS`.
2. For iPhone, select your signing team and a unique bundle identifier.
3. Open **モデル設定** and choose **共通モデル** and **声モデル**. The dictionary is detected automatically.
4. Press **モデルを準備**, then **生成して再生**. Playback starts after the complete utterance has been generated.

The [sample app guide (Japanese)](docs/sample-app.ja.md) explains each control, styles, replay, RTF and voice switching.

For public repositories, alternatively enter an HTTPS URL for a release's `download.json`. Each file is downloaded and
verified before installation. Copying the two model folders into the iOS app's Documents folder
also works. The app's speech synthesis works offline once resources are present.

## Use in Swift

Add this repository as a Swift Package, then import `SBV2CoreML`:

```swift
import Foundation
import SBV2CoreML

// JVNV sample voice: speaker 0 and Neutral style.
func renderSample(paths: ModelPaths) async throws -> Data {
    let speech = SpeechSynthesizer()
    try await speech.load(paths)
    try await speech.warmUp()
    let audio = try await speech.synthesize("こんにちは。お元気ですか？")
    let wav = try audio.wav()
    try await speech.unload()
    return wav
}
```

`ModelPaths` takes local BERT, voice and dictionary directory URLs. Keep the synthesizer
loaded between utterances in a chat application. The function above is a single WAV example.
The sample uses `synthesize` and `AudioPlayer` to play a complete utterance.
The SDK also exposes an optional `stream` API for applications that need segment delivery;
see the [API reference](docs/api-reference.ja.md).
Read `VoiceInfo.styles`/`speakers` when choosing options: not every voice has a `Neutral` style.
Cancellation takes effect between native inference calls; an in-flight Core ML call is allowed to finish.

## Convert a voice

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt
.venv/bin/sbv2-coreml doctor
.venv/bin/sbv2-coreml convert --aivm voice.aivm --output models/my-voice
```

The pinned upstream source is acquired automatically. [More inputs and validation details](docs/conversion.md).
Conversion requires macOS/Python 3.11; the runtime itself only requires the Apple SDK and models.

## Scope and licenses

The supported profile is Japanese JP-Extra, 44.1 kHz, hop 512, 1024-dimensional BERT,
256-dimensional styles, and the documented decoder architecture. Arbitrary SBV2 forks and
AIVMX-only downloads are not supported. Internal capacity limits can require additional text splits.

Code is distributed under **AGPL-3.0**, with retained notices for third-party components.
The converted JVNV voice and common DeBERTa carry **CC BY-SA 4.0**; the dictionary has separate BSD notices.
Other voices retain their own terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
This repository does not grant permission to use third-party character artwork or trademarks.

## Development

```sh
swift test
PYTHONPATH=converter .venv/bin/python -m unittest discover -s converter/tests -v
python3 scripts/check_docs.py --swift
```

No remote repository, package registry or model upload is created by these commands.
