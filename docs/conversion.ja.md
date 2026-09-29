# 変換ガイド・CLIリファレンス

[ドキュメント一覧](README.ja.md) · [English](conversion.md)

声モデルの変換はApple Silicon Mac、Python 3.11で行います。
互換性のある声を追加する場合、共通BERTを毎回変換する必要はありません。
対応は[モデル仕様](model-format.ja.md)に記載した日本語JP-Extraです。

## 環境を準備する

このリポジトリのルートで実行します。初回の依存関係・SBV2ソース取得にはインターネット接続が必要です。

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt
.venv/bin/sbv2-coreml doctor
.venv/bin/sbv2-coreml --version
```

`doctor`はPython・主要パッケージ・macOS環境を表示します。Core MLモデルの読み込みや空き容量まで検証する診断ではありません。
配布済みwheelを使う場合も変換用の依存関係が必要です。上のソースからのインストールが、この準備版の基準手順です。
アプリで変換済みモデルを再生するだけなら、この環境は不要です。

## AIVMファイルを変換する

原本を`input/voice.aivm`へ置いた場合の例です。`models/my-voice`は新しいフォルダ名にします。

```sh
.venv/bin/sbv2-coreml convert \
  --aivm input/voice.aivm \
  --output models/my-voice
```

AIVMに埋め込まれた設定、スタイルベクトル、存在する場合はライセンス文を取り出します。
AIVMXはONNX形式の別ファイルで、この変換の入力には使えません。

## 自分で学習したモデルを変換する

```text
input/my-voice/
  model.safetensors
  config.json
  style_vectors.npy
```

```sh
.venv/bin/sbv2-coreml convert \
  --checkpoint input/my-voice/model.safetensors \
  --config input/my-voice/config.json \
  --styles input/my-voice/style_vectors.npy \
  --output models/my-trained-voice
```

設定とスタイルベクトルが重みの隣に上記の名前である場合、`--config`と`--styles`は省略できます。
`.pt`／`.pth`を直接渡す手順は用意していません。学習側で対応するSafetensorsを出力してください。
推論に必要な重みが欠けていれば停止します。欠けた層をランダム初期化したまま出力することはありません。

## AivisHubから取得して変換する

使いたいモデルの正規のページURLを確認し、次の入力待ちで貼り付けます。

```sh
read -r AIVIS_URL
.venv/bin/sbv2-coreml inspect-hub "$AIVIS_URL"
.venv/bin/sbv2-coreml convert --aivis-url "$AIVIS_URL" --output models/hub-voice
```

URLは`https://hub.aivis-project.com/aivm-models/`にモデルUUIDが続く形です。
`inspect-hub`は原本の有無・形式・版・ライセンス種別などを確認し、重みはダウンロードしません。
`convert`はAPIで提供されるAIVMを取得し、APIが示すSHA-256と照合します。
AIVMXしか公開されていないモデル、対象外の構造、取得権限がないモデルは使えません。
変換できることと再配布できることは別です。[各モデルのライセンス](licenses.ja.md)を確認してください。

## 検証とサンプルでの利用

```sh
.venv/bin/sbv2-coreml verify models/my-voice
```

成功すると`status: ok`と検証ファイル数を表示します。これは`checksums.json`に列挙されたファイルの整合性確認で、
音質判定や全文章の動作保証ではありません。列挙されていないローカルキャッシュ等は対象外です。

サンプルアプリで**Voice**に出力フォルダを選び、「準備・ウォームアップ」を行います。
BERT・辞書は共通フォルダを引き続き使います。スタイルは声ごとに名前が異なるため、一覧から選んでください。

## convertの引数

| 引数 | 内容・既定値 |
|---|---|
| `--aivis-url` / `--aivm` / `--checkpoint` | 入力。いずれか1つが必須 |
| `--output` | 新しい出力フォルダ。必須。既存出力を上書きしない |
| `--config` / `--styles` | Safetensors用の設定・スタイル。既定は重みの隣 |
| `--name` | `model.json`へ記録する名前。既定は出力フォルダ名 |
| `--cache` | ダウンロード保存先。既定は`~/Library/Caches/sbv2-coreml-converter` |
| `--source-root` | 取得済み／カスタムのSBV2ソース。通常は省略して固定版を自動取得 |
| `--license-file` | 保存するライセンス文。AIVMの埋め込み文があれば省略可能 |
| `--license-id` | 再配布時のライセンス識別子。実際の許諾に従って指定 |
| `--source-url` | 原本の出典URL |

原本は変更しません。変換の途中経過は出力先の親に作った一時フォルダへ保存し、成功・失敗のどちらでも片付けます。
作業中は完成モデルより大きい空き容量が必要です。原本・キャッシュ・完成モデルは処理後も残ります。
出力にはCore MLモデル、設定、スタイル、検証結果、出典、チェックサムが含まれます。

## 精度と変換方式

原本PyTorchからEncoder／DP、SDP、Flow、Decoderを直接変換します。ONNXを中間ファイルにせず、ONNX Runtimeも不要です。
固定版SBV2ソースの不要なORT読み込みは一時コピー上で遅延読み込みへ変更し、変更前後のハッシュを出典に記録します。
元のソースファイルは変更しません。重みの再学習、整数量子化は行いません。

| 検証 | 内容 |
|---|---|
| 入力・重み | 構造、スタイル形状、必要な重みの存在と読み込み結果 |
| 個別ブロック | Encoder／DP、SDP、Flowの比較。SDP式の書き換えも確認 |
| FP32波形 | 固定した合成入力でPyTorchと比較。SNR 60 dB以上、最大絶対誤差0.001以下 |
| 固定長Decoder | 混合FP32／FP16で比較。SNR 35 dB以上、最大絶対誤差0.05以下 |
| 精度フォールバック | 固定長Decoderが基準を満たさない場合はFP32で再変換し、FP32基準で確認 |
| 重み共有 | 多機能モデル化する前後のCPU出力が、検証した入力で完全一致することを確認 |

Decoderの重み正規化はFP32で畳み込んでから変換し、その書き換え自体も照合します。
これらは固定入力での数値検証です。任意の文章の知覚的な音質一致を保証しません。
`decoder_validation.json`には実際の精度を記録します。名前が`_fp16`でもFP32フォールバックの場合があります。
公開前には、自然文・各スタイルを原本と聴き比べ、対象端末でも確認してください。

## 再配布用アーカイブを作る

原本の利用条件を確認し、ライセンス文と出典を付けて変換します。
以下の`cc-by-sa-4.0`は、その条件で提供する権利がある自作モデルの場合の例です。

```sh
.venv/bin/sbv2-coreml convert \
  --checkpoint input/my-voice/model.safetensors \
  --license-file input/my-voice/LICENSE.md \
  --license-id cc-by-sa-4.0 \
  --output models/my-release-voice
.venv/bin/sbv2-coreml package \
  --input models/my-release-voice \
  --output artifacts/my-release-voice.tar.gz
```

出典の公開ページがある場合は`--source-url`も指定します。ACMLなどは`--license-id other`として原文を保存します。
`package`はライセンスID・文・出典ファイルがない出力を拒否します。
ハッシュに列挙された資産をアーカイブ化し、SHA-256とサイズのJSONも出力します。
このコマンドは利用許諾の法的な可否までは自動判定しません。
`download.json`とHugging Face向けモデルカードの準備は[公開手順](releasing.ja.md)を参照してください。

## 共通BERTを再構築する場合

通常は配布済みの共通モデルを使います。開発者が再構築する場合は
`ku-nlp/deberta-v2-large-japanese-char-wwm`の版
`547b0e8b044fba3f9b84d0ab9f990440bd130c8b`を取得し、`config.json`、`model.safetensors`、`vocab.txt`を揃えます。
`input/bert`へ置いた場合：

```sh
.venv/bin/sbv2-coreml build-bert --checkpoint-dir input/bert --output models/bert
```

FP32の2ブロック、候補長64／128／256を出力します。辞書と公開用モデルカードは別に用意します。
現在の準備版は既存の変換済みBERTで実機確認しており、このラッパーからの全BERT再変換は再実行していません。
[検証済み範囲](verification.ja.md)を併せて確認してください。
