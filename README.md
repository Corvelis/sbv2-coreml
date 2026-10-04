# SBV2 Core ML

**Style-Bert-VITS2 JP-Extraの日本語音声合成を、iPhoneとApple Silicon Macで使うためのSDKです。**
Core MLで推論し、Swift SDK、iPhone／Mac用サンプルアプリ、WAV出力CLI、声モデルの変換ツールを含みます。
アプリ内でONNX Runtime・Python・Flutterを使わずに動作します。

**ドキュメントは日本語を基本としています。** 英語は補助資料として[English README](README.en.md)にまとめています。

## はじめに

| やりたいこと | 案内 |
|---|---|
| サンプルアプリで音声を出す | [クイックスタート](docs/getting-started.ja.md) |
| 自分のXcodeアプリへSDKを組み込む | [SDK導入・実装ガイド](docs/sdk-guide.ja.md) |
| サンプルの設定や再生操作を調べる | [サンプルアプリの使い方](docs/sample-app.ja.md) |
| AivisHubや自作SBV2モデルの声を変換する | [モデル変換ガイド](docs/conversion.ja.md) |
| API・モデル仕様・検証記録を調べる | [日本語ドキュメント一覧](docs/README.ja.md) |
| 初期化失敗、遅延、音切れ、容量を調べる | [トラブルシューティング](docs/troubleshooting.ja.md) |

## 配布物

SDKとモデルは別々に配布します。SDKを取得しただけではモデルはダウンロードされません。

| 配布物 | 配布先 |
|---|---|
| SDK・サンプル・変換ツール・ドキュメント | [Corvelis/sbv2-coreml](https://github.com/Corvelis/sbv2-coreml)、タグ[v0.1.0-dev2](https://github.com/Corvelis/sbv2-coreml/tree/v0.1.0-dev2) |
| 共通BERT・Open JTalk辞書 | [AILogDev/sbv2-coreml-common](https://huggingface.co/AILogDev/sbv2-coreml-common) |
| サンプルの声：JVNV F1 JP-Extra | [AILogDev/sbv2-coreml-jvnv-f1-jp](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) |

現在は3リポジトリともPrivateです。アクセス権のあるアカウントで取得してください。
モデルの固定版と取得方法は[クイックスタート](docs/getting-started.ja.md)、配布状況は[公開手順](docs/releasing.ja.md)に記載しています。

## 対応環境と構成

- iPhone：iOS 18以上。Mac：macOS 15以上のApple Silicon。
- モデル変換：Apple Silicon MacとPython 3.11。
- モデル：文書化した構造の日本語JP-Extra、44.1 kHz、hop 512、BERT特徴1024次元、スタイル256次元。
- 推論：BERT、Encoder／DP、SDP、Flow、波形DecoderをCore MLで実行します。日本語の読み・アクセント処理にはOpen JTalkを使います。
- 声の追加：共通BERTと辞書を使い回し、互換性のある声モデルを別フォルダで保持します。

通常版SBV2、多言語版、任意の派生構造、ONNX／AIVMXだけを入力した変換は対象外です。
モデル容量の上限により、長い文章を追加で分割することがあります。[モデル仕様](docs/model-format.ja.md)を参照してください。

## XcodeへSDKを追加する

1. **File → Add Package Dependencies**で、次のURLを指定します。
2. **Exact Version: 0.1.0-dev2**を選びます。
3. アプリのターゲットへ **SBV2CoreML** を追加します。

```text
https://github.com/Corvelis/sbv2-coreml.git
```

Privateの間は、GitHubリポジトリへのアクセス権が必要です。
以下は、準備済みのモデルから1つのWAVを生成する例です。

```swift
import Foundation
import SBV2CoreML

// サンプルのJVNV：話者ID 0、スタイルNeutral。
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

`ModelPaths`にはローカルのBERT・声・辞書のフォルダURLを渡します。
繰り返し使うアプリでは`SpeechSynthesizer`を保持し、準備時に`load`と`warmUp`を実行します。
各文章では`synthesize`を呼びます。[SDK導入ガイド](docs/sdk-guide.ja.md)に保存場所、停止、声の切り替え、モデル取得の実装をまとめています。

## サンプルアプリを使う

`Examples/Apple/SBV2Demo.xcodeproj`をXcodeで開きます。

1. `SBV2Demo-iOS`または`SBV2Demo-macOS`を選びます。iPhoneでは自分のTeamと固有のBundle Identifierを設定します。
2. **モデル設定**で**共通モデル**と**声モデル**のフォルダを選びます。辞書は共通フォルダから自動認識します。
3. **モデルを準備**を押し、準備完了後に文章を入力して**生成して再生**を押します。

サンプルはLLMと連携せず、全文を合成してから1つのPCMバッファを再生します。
スタイル変更、再再生、停止に対応します。操作は[サンプルアプリの使い方](docs/sample-app.ja.md)を参照してください。
SDKには区間ごとのPCMを受け取る`stream` APIもあります。付属GUI／CLIは`synthesize`を使います。
停止はネイティブ推論の区切りで反映されます。[APIリファレンス](docs/api-reference.ja.md)に詳しい仕様を記載しています。

## MacのターミナルからWAVを作る

Xcodeと2つのモデルフォルダを用意して実行します。

```sh
swift run -c release sbv2-say \
  /path/to/sbv2-coreml-common/bert \
  /path/to/sbv2-coreml-jvnv-f1-jp \
  /path/to/sbv2-coreml-common/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
```

文章の後に`Happy 0`のようにスタイルと話者IDを指定することもできます。
初回にはCore MLのコンパイルが発生します。生成されたキャッシュを残すと次回の準備時間を短縮できます。

## 自分の声モデルを変換する

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt
.venv/bin/sbv2-coreml doctor
.venv/bin/sbv2-coreml convert --aivm voice.aivm --output models/my-voice
```

AivisHubのURL、AIVM、またはSafetensorsと設定・スタイルベクトルから直接Core MLへ変換します。
必要な元のSBV2ソースは固定コミットから取得します。詳しい入力方法と検証手順は[モデル変換ガイド](docs/conversion.ja.md)を参照してください。

## 検証状況とライセンス

これはプレリリースです。サンプルのJVNV、iPhone 17 Pro、Apple Silicon Macで確認した条件を[検証記録](docs/verification.ja.md)にまとめています。
全機種・全文章・全モデルでのRTF 0.1や、知覚的な音質の完全一致を保証するものではありません。
Public切り替え後の、サンプルからの匿名HTTPS取得・合成・再起動後の再利用確認が残っています。

コードは**AGPL-3.0**、変換済みJVNVと共通BERTは**CC BY-SA 4.0**です。
辞書は別のBSD系条件、追加する声はそれぞれの原本の条件に従います。
[ライセンスと出典](THIRD_PARTY_NOTICES.md)、[日本語ライセンスガイド](docs/licenses.ja.md)を参照してください。

## 開発時の確認

```sh
swift test
PYTHONPATH=converter .venv/bin/python -m unittest discover -s converter/tests -v
python3 scripts/check_docs.py --swift
```

これらはローカルの検証コマンドです。モデルのアップロードなどの公開操作は[公開手順](docs/releasing.ja.md)で行います。
