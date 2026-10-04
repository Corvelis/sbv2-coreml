# クイックスタート

[ドキュメント一覧](README.ja.md) · [SDKを自分のアプリへ組み込む](sdk-guide.ja.md)

付属のサンプルアプリで、日本語の文章を読み上げます。モデルの変換は不要です。
必要なのはXcode、iOS 18以上のiPhone、またはmacOS 15以上のApple Silicon Macです。

## 1. ソースを取得する

[ReleaseのソースZIP](https://github.com/Corvelis/sbv2-coreml/releases/tag/v0.1.0-dev4)をダウンロードして展開します。
Gitを使う場合は次のコマンドでも取得できます。

```sh
git clone --branch v0.1.0-dev4 https://github.com/Corvelis/sbv2-coreml.git
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
| [共通モデル](https://huggingface.co/AILogDev/sbv2-coreml-common) | BERT・Open JTalk辞書 | 約1.52 GB |
| [JVNV F1 JP-Extra](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) | 声モデル | 約294 MB |

ダウンロードと初回コンパイルには、上記の容量に加えて空き容量が必要です。

1. アプリ右上のスライダーアイコンから **モデル設定** を開く。
2. **URLからモデルを取得** を開き、**取得するモデル → 共通モデル** を選ぶ。
3. 次の共通モデルURLを貼り付け、**ダウンロード** を押して完了まで待つ。
4. **取得するモデル → 声モデル** に切り替え、声モデルURLで同じ操作を行う。
5. 両方を取得したら **完了** でメイン画面へ戻る。

**共通モデルURL**

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/d9cc585298e2d59fb1df384fb62a1e15d73f8add/download.json
```

**声モデルURL**

```text
https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp/resolve/17faac326f120b171170f10807bb26b0da8257d9/download.json
```

この欄には`download.json`のURLを入力します。リポジトリのWebページや圧縮アーカイブのURLは使えません。
取得後の音声合成はオフラインで動作します。

### Macでダウンロードしてフォルダを選ぶ場合

[Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)をインストールし、リポジトリのルートで実行します。

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision d9cc585298e2d59fb1df384fb62a1e15d73f8add \
  --local-dir models/sbv2-coreml-common
hf download AILogDev/sbv2-coreml-jvnv-f1-jp \
  --revision 17faac326f120b171170f10807bb26b0da8257d9 \
  --local-dir models/sbv2-coreml-jvnv-f1-jp
```

取得後、アプリの **モデル設定** で **共通モデル** と **声モデル** のフォルダを選びます。
共通モデルを選ぶとBERTと辞書を自動認識します。
iPhoneへ移す場合は、Finderのファイル共有でサンプルアプリへ2フォルダを丸ごとコピーするか、Filesから選べる場所へ置きます。

```text
models/
  sbv2-coreml-common/
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
コンパイルキャッシュを残すと、次回の準備時間を短縮できます。
入力の長さが変わると、初回推論の準備が追加で発生する場合があります。

再起動後、モデルを選び直す必要がある場合は、**モデル設定**から取得済みフォルダを指定してください。
サンプルのDocuments直下に`sbv2-coreml-common`と`sbv2-coreml-jvnv-f1-jp`を置いた場合は自動検出します。
iPhoneでは **ファイル → このiPhone内 → SBV2 Core ML** から保存済みフォルダを確認できます。

## MacのターミナルからWAVを作る

モデルを上記の`models/`へ取得した後、リポジトリのルートで実行します。

```sh
swift run -c release sbv2-say \
  models/sbv2-coreml-common/bert \
  models/sbv2-coreml-jvnv-f1-jp \
  models/sbv2-coreml-common/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
afplay output.wav
```

出力はモノラル44.1 kHz、16 bit PCMです。文章の後に`Happy 0`のようにスタイル名と話者IDを指定できます。

モデルが読み込めない、音が出ない場合は[トラブルシューティング](troubleshooting.ja.md)を参照してください。
