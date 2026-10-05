# SBV2 Core ML

[English](README.en.md)

Style-Bert-VITS2 JP-Extraの日本語音声合成を、iPhoneとApple Silicon Macで使えるSwift SDKです。
Core MLで推論し、iPhone／Mac用サンプルアプリ、WAV出力CLI、声モデルの変換ツールを含みます。
音声合成は端末内で完結します。アプリでONNX RuntimeやPythonを実行する必要はありません。

## はじめに

| やりたいこと | 案内 |
|---|---|
| サンプルアプリで音声を出す | [クイックスタート](docs/getting-started.ja.md) |
| 自分のXcodeアプリへSDKを組み込む | [SDK導入ガイド](docs/sdk-guide.ja.md) |
| サンプルの設定・再生操作を調べる | [サンプルアプリの使い方](docs/sample-app.ja.md) |
| AivisHubや自作モデルの声を変換する | [モデル変換ガイド](docs/conversion.ja.md) |
| メソッド・引数を調べる | [APIリファレンス](docs/api-reference.ja.md) |
| モデルが読み込めない・音が出ない | [トラブルシューティング](docs/troubleshooting.ja.md) |

## 必要なもの

- **iPhone：** iOS 18以上。**Mac：** macOS 15以上のApple Silicon。
- **Xcode：** SDKの組み込み、サンプルアプリのビルドに使用します。
- **共通モデルと声モデル：** 下記の2つを取得します。共通BERT・辞書は、互換性のある声同士で使い回せます。

| 配布物 | 入手先 |
|---|---|
| SDK・サンプルアプリ・変換ツール | [GitHub Releases](https://github.com/Corvelis/sbv2-coreml/releases/tag/v0.1.0-dev5) |
| 共通BERT・Open JTalk辞書（約503 MB） | [AILogDev/sbv2-coreml-common](https://huggingface.co/AILogDev/sbv2-coreml-common) |
| JVNV F1 JP-Extraの声モデル（約294 MB） | [AILogDev/sbv2-coreml-jvnv-f1-jp](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) |

SDK・ソースZIPにモデルの重みは含まれていません。取得方法は[クイックスタート](docs/getting-started.ja.md)を参照してください。
初回のCore MLコンパイルには、モデル本体とは別に空き容量が必要です。

## XcodeへSDKを追加する

1. **File → Add Package Dependencies**で、次のURLを指定します。
2. **Exact Version: 0.1.0-dev5**を選びます。
3. アプリのターゲットへ **SBV2CoreML** を追加します。

```text
https://github.com/Corvelis/sbv2-coreml.git
```

モデルを配置したら、次のようにWAVを生成できます。

```swift
import Foundation
import SBV2CoreML

// JVNVサンプル：話者ID 0、スタイルNeutral。
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

`common`と`voice`には、それぞれ取得したモデルフォルダのURLを渡します。
繰り返し使うアプリでは`SpeechSynthesizer`を保持し、`load`と`warmUp`を準備時に実行してください。
再生・停止・声の切り替えは[SDK導入ガイド](docs/sdk-guide.ja.md)にまとめています。

## サンプルアプリで試す

`Examples/Apple/SBV2Demo.xcodeproj`をXcodeで開きます。

1. `SBV2Demo-iOS`または`SBV2Demo-macOS`を選びます。iPhoneでは自分のTeamと固有のBundle Identifierを設定します。
2. **モデル設定**で**共通モデル**と**声モデル**のフォルダを選びます。辞書は共通フォルダから自動認識します。
3. **モデルを準備**を押し、準備完了後に文章を入力して**生成して再生**を押します。

全文を合成してから再生します。スタイル変更、停止、生成済み音声の再再生にも対応しています。
[サンプルアプリの使い方](docs/sample-app.ja.md)

## MacのターミナルからWAVを作る

リポジトリのルートで、次のように実行します。
モデルを`models/`へ取得する手順は[クイックスタート](docs/getting-started.ja.md)に記載しています。

```sh
swift run -c release sbv2-say \
  models/sbv2-coreml-common/bert \
  models/sbv2-coreml-jvnv-f1-jp \
  models/sbv2-coreml-common/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
afplay output.wav
```

文章の後に`Happy 0`のようにスタイルと話者IDを指定できます。

## 自分の声モデルを変換する

Apple Silicon MacとPython 3.11を使い、リポジトリのルートで実行します。

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt
.venv/bin/sbv2-coreml convert --aivm voice.aivm --output models/my-voice
```

AivisHubのURL、AIVM、またはSafetensors・設定・スタイルベクトルからCore MLへ変換できます。
共通BERTを変換し直す必要はありません。[モデル変換ガイド](docs/conversion.ja.md)

対応するのは[モデル仕様](docs/model-format.ja.md)に記載した日本語JP-Extraモデルです。
ONNX／AIVMXだけを入力した変換、通常版SBV2、多言語版は対象外です。

## 共通モデルの容量を減らす

`compress-common`で共通BERTの重みを8bitまたはFP16で保存できます。声モデルは別のまま使用します。
通常配布の共通モデルは8bit版です。JVNVの声と合わせて約797 MBで、FP32版の約1.81 GBから約56%小さくなっています。
モデル読み込み後の最初のBERT実行は長くなるため、`load`と`warmUp`を準備時に実行してください。
生成したモデルは、使う声・文章・端末で音質と速度を確認してから採用してください。
[容量削減の手順](docs/compression.ja.md)

## ライセンス

コードは**AGPL-3.0**、変換済みJVNVと共通BERTは**CC BY-SA 4.0**です。
辞書と追加する声には、それぞれの利用条件が適用されます。
[ライセンスガイド](docs/licenses.ja.md) · [第三者表記と出典](THIRD_PARTY_NOTICES.md)
