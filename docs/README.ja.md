# SBV2 Core ML ドキュメント

[English](../README.en.md)

Style-Bert-VITS2 JP-ExtraをiPhone／Apple Silicon Macで使うためのSDK、サンプル、変換ツールです。
アプリ内の推論にPython・Flutter・ONNX Runtimeは不要です。

## 目的から読む

| やりたいこと | 最初に読むページ |
|---|---|
| サンプルで音声を出す | [クイックスタート](getting-started.ja.md) |
| サンプルのボタン、スタイル、時間表示を調べる | [サンプルアプリの使い方](sample-app.ja.md) |
| 自分のXcodeプロジェクトへ組み込む | [SDK導入・実装ガイド](sdk-guide.ja.md) |
| メソッド、引数、停止処理を調べる | [Swift APIリファレンス](api-reference.ja.md) |
| AivisHubや自作モデルの声を使う | [変換ガイド・CLIリファレンス](conversion.ja.md) |
| モデルの構造、保存場所、サイズを調べる | [モデル仕様](model-format.ja.md) |
| INT8版と元のFP32版を選ぶ・切り替える | [共通モデルの選び方](model-selection.ja.md) |
| 共通モデルのBERTを圧縮する | [容量削減](compression.ja.md) |
| 初期化失敗、遅延、容量、音切れを調べる | [トラブルシューティング](troubleshooting.ja.md) |
| コードやモデルを再配布する | [ライセンスと出典](licenses.ja.md) |

## 配布物

| 配布物 | 内容 | 入手・配置 |
|---|---|---|
| SDKとサンプル | Swift Package、iPhone／Macアプリ、WAV出力CLI、Python変換ツール | [Corvelis/sbv2-coreml](https://github.com/Corvelis/sbv2-coreml)／Code → Download ZIP |
| 共通モデル | 日本語BERTとOpen JTalk辞書。INT8：約503 MB、元のFP32：約1.52 GB | [AILogDev/sbv2-coreml-common](https://huggingface.co/AILogDev/sbv2-coreml-common) |
| サンプルの声 | JVNV F1 JP-Extra、約294 MB | [AILogDev/sbv2-coreml-jvnv-f1-jp](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) |

容量は展開後の配布ファイルの概算です。ダウンロード一時ファイルとCore MLのコンパイルキャッシュは別途必要です。
互換性のある声パッケージを追加する際、共通BERT・辞書の再ダウンロードは不要です。

## 対応範囲

- iOS 18以上、macOS 15以上のApple Silicon。速度の確認には実機を使ってください。
- 日本語JP-Extra、44.1 kHz、文書化した構造のモデル。通常版SBV2、多言語版、任意の派生構造は対象外です。
- 変換はApple Silicon Mac、Python 3.11で行います。変換済みモデルを使うだけならPythonは不要です。

コードはAGPL-3.0、JVNVと共通BERTはCC BY-SA 4.0です。辞書・他の声にはそれぞれの条件があります。
本文の要約に加え、[ライセンス原文と第三者表記](../THIRD_PARTY_NOTICES.md)も確認してください。
