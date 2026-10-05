# クイックスタート

[ドキュメント一覧](README.ja.md) · [SDKを自分のアプリへ組み込む](sdk-guide.ja.md)

付属のサンプルアプリで、日本語の文章を読み上げます。モデルの変換は不要です。
必要なのはXcode、iOS 18以上のiPhone、またはmacOS 15以上のApple Silicon Macです。

## 1. ソースを取得する

[GitHub](https://github.com/Corvelis/sbv2-coreml)の **Code → Download ZIP** でソースを取得して展開します。
Gitを使う場合は次のコマンドでも取得できます。

```sh
git clone https://github.com/Corvelis/sbv2-coreml.git
cd sbv2-coreml
```

SDKを自分のアプリへ組み込む場合は[SDK導入ガイド](sdk-guide.ja.md)へ進んでください。

## 2. サンプルアプリを起動する

`Examples/Apple/SBV2Demo.xcodeproj`をXcodeで開きます。

### Mac

1. Schemeに **SBV2Demo-macOS**、実行先にApple Silicon Macを選ぶ。
2. Runを押す。

### iPhone

1. Schemeに **SBV2Demo-iOS** を選ぶ。
2. ターゲットの **Signing & Capabilities** で自分のTeamと固有のBundle Identifierを設定する。
3. iPhoneを接続して実行先に選び、Runを押す。端末で開発者モード等の確認が求められたら設定する。

## 3. 共通モデルと声モデルを取得する

ソースZIPにはモデルの重みを含めていません。次の2つが必要です。

| モデル | 内容 | 配布ファイルの容量 |
|---|---|---|
| [共通モデル・INT8版](https://huggingface.co/AILogDev/sbv2-coreml-common) | BERT・Open JTalk辞書 | 約503 MB |
| [JVNV F1 JP-Extra](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) | 声モデル | 約294 MB |

この手順では容量を抑えたINT8版を取得します。元のFP32版（共通モデル約1.52 GB）を使う場合は、
[INT8版とFP32版の選び方・取得URL](model-selection.ja.md)を参照してください。声モデルは両方で共通です。
ダウンロードと初回コンパイルには、上記の容量に加えて空き容量が必要です。

1. アプリ右上のスライダーアイコンから **モデル設定** を開く。
2. **URLからモデルを取得** を開き、**取得するモデル → 共通モデル** を選ぶ。
3. **共通モデルの版 → INT8（約503 MB）** を選ぶ。取得URLが自動設定されるので、**ダウンロード** を押して完了まで待つ。
4. **取得するモデル → 声モデル** に切り替える。JVNVの取得URLが自動設定されるので、**ダウンロード** を押す。
5. 両方を取得したら **完了** でメイン画面へ戻る。

**共通モデルURL（INT8版）**

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d/int8/download.json
```

**声モデルURL**

```text
https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp/resolve/17faac326f120b171170f10807bb26b0da8257d9/download.json
```

INT8／FP32の選択で上記の共通モデルURLが自動設定されます。別の配布元を指定する場合は、
**共通モデルの版 → カスタムURL**でHTTPSの`download.json` URLを入力します。Webページや圧縮アーカイブのURLは使えません。
取得後の音声合成はオフラインで動作します。

### Macでダウンロードしてフォルダを選ぶ場合

[Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)をインストールし、リポジトリのルートで実行します。

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "int8/*" --local-dir models
hf download AILogDev/sbv2-coreml-jvnv-f1-jp \
  --revision 17faac326f120b171170f10807bb26b0da8257d9 \
  --local-dir models/sbv2-coreml-jvnv-f1-jp
```

取得後、アプリの **モデル設定** で **共通モデル** と **声モデル** のフォルダを選びます。
共通モデルは`models/int8/`を選ぶと、BERTと辞書を自動認識します。
iPhoneへ移す場合は、Finderのファイル共有でサンプルアプリへ2フォルダを丸ごとコピーするか、Filesから選べる場所へ置きます。

```text
models/
  int8/
    bert/vocab.txt
    bert/coreml_blocks/
    dictionary/sys.dic
  sbv2-coreml-jvnv-f1-jp/
    config.json
    style_vectors.npy
    coreml_voice/voice_shared.mlpackage/
```

`.mlpackage`はフォルダ全体がモデルです。中の`model.mlmodel`だけを取り出さないでください。
iCloud等を使う場合も、中身がすべて端末へダウンロードされている必要があります。

## 4. 音声を生成して再生する

1. **モデルを準備** を押し、準備完了まで待つ。
2. 文章欄へ「こんにちは。」と入力する。
3. **生成して再生** を押す。全文の生成後に音声が再生されます。

準備後はスタイルを変更できます。JVNVにはNeutral、Angry、Disgust、Fear、Happy、Sad、Surpriseがあります。
停止ボタンで合成・再生を停止し、再再生ボタンで最後の音声をもう一度再生できます。
[サンプルアプリの使い方](sample-app.ja.md)

初回はCore MLのコンパイル・モデルの読み込み・ウォームアップに時間がかかります。
INT8版は読み込み後の最初のBERT実行にも時間がかかるため、**モデルを準備**の完了を待ってください。
準備時間と合成速度の比較は[モデルの選び方](model-selection.ja.md)にあります。
コンパイルキャッシュを残すと、次回の準備時間を短縮できます。
入力の長さが変わると、初回推論の準備が追加で発生する場合があります。

再起動後、モデルを選び直す必要がある場合は、**モデル設定**から取得済みフォルダを指定してください。
上の例の`int8/`は、共通モデルとして自分で選択します。自動検出を使う場合は、フォルダ名を`sbv2-coreml-common`へ変更し、
Documents直下に`sbv2-coreml-jvnv-f1-jp`と一緒に置いてください。
iPhoneでは **ファイル → このiPhone内 → SBV2 Core ML** から保存済みフォルダを確認できます。

## MacのターミナルからWAVを作る

モデルを上記の`models/`へ取得した後、リポジトリのルートで実行します。
FP32版の場合は、下の`int8`を`float32`へ置き換えます。

```sh
swift run -c release sbv2-say \
  models/int8/bert \
  models/sbv2-coreml-jvnv-f1-jp \
  models/int8/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
afplay output.wav
```

出力はモノラル44.1 kHz、16 bit PCMです。文章の後に`Happy 0`のようにスタイル名と話者IDを指定できます。

モデルが読み込めない、音が出ない場合は[トラブルシューティング](troubleshooting.ja.md)を参照してください。
