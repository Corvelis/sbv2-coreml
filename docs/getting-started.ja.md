# クイックスタート

[ドキュメント一覧](README.ja.md) · 次：[自分のアプリへ組み込む](sdk-guide.ja.md)

まず付属サンプルで「こんにちは。」を再生します。モデルを変換する作業は不要です。

## 1. ソースとモデルを用意する

必要なのはソース一式、共通モデル、声モデルの3つです。ソースGit／ZIPには大きなモデルファイルを含めていません。
この公開準備用の作業コピーでは、`artifacts/releases/`に次の配布ファイルがあります。
配布ファイルを別途受け取った場合も、同じ場所に置くと以下のコマンドをそのまま使えます。

```text
sbv2-coreml/                     ← Package.swiftがあるフォルダ
  Package.swift
  Examples/
  artifacts/releases/
    sbv2-coreml-common-0.1.0-dev1.tar.gz
    sbv2-coreml-jvnv-f1-jp-0.1.0-dev1.tar.gz
```

ターミナルで`Package.swift`のあるフォルダを開き、展開します。`models/`は新規、または空の状態で始めてください。

```sh
mkdir -p models
tar -xzf artifacts/releases/sbv2-coreml-common-0.1.0-dev1.tar.gz -C models
tar -xzf artifacts/releases/sbv2-coreml-jvnv-f1-jp-0.1.0-dev1.tar.gz -C models
```

Finderで展開しても構いません。最終的に次の配置になれば準備完了です。

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
モデルのハッシュ確認は[変換ガイドのverify](conversion.ja.md)に記載しています。

## 2. Macで起動する

1. Xcodeで`Examples/Apple/SBV2Demo.xcodeproj`を開く。
2. Schemeを`SBV2Demo-macOS`、実行先をApple Silicon Macにする。
3. Runを押す。
4. 右上の**モデル設定**を開き、**共通モデル**で`sbv2-coreml-common`を選ぶ。内部のBERTと辞書を自動認識します。
5. **声モデル**で`sbv2-coreml-jvnv-f1-jp`を選び、「完了」でメイン画面へ戻る。
6. 「モデルを準備」を押し、準備完了まで待つ。
7. 文章欄に「こんにちは。」と入力して「生成して再生」を押す。全文の生成後に再生が始まります。

声のスタイルを変える場合は準備後の文章カード右上で選びます。JVNVにはNeutral、Angry、Disgust、Fear、Happy、Sad、Surpriseがあります。
再生中は停止ボタン、完了後は再再生ボタンが表示されます。再再生は生成済みの音声を使います。
読み上げを止めるときは停止ボタンを押します。処理中のCore ML呼び出しが終わるまで停止完了を待つ場合があります。

## 3. iPhoneで起動する

1. 同じXcodeプロジェクトで`SBV2Demo-iOS`を選ぶ。
2. ターゲットの「Signing & Capabilities」で自分のTeamと固有のBundle Identifierを指定する。
3. 接続したiPhoneを実行先にしてRunする。実行対象はiOS 18以上です。
4. 展開済みの2つのモデルフォルダをiPhoneへ移す。Finderのファイル共有でサンプルアプリへコピーするか、Filesから選択できる場所へ置きます。
5. **モデル設定**の**共通モデル**で共通フォルダ、**声モデル**で声フォルダを選ぶ。
6. 「モデルを準備」→「生成して再生」の順に操作する。

サンプルのDocuments直下に上記の名前で2フォルダを置いた場合は、起動時に自動検出します。
iCloudなどから選択する場合は、フォルダ内のモデルが端末へ完全にダウンロードされていることを確認してください。
読み取り専用の場所でコンパイルキャッシュの保存に失敗した場合は、サンプルのDocumentsへコピーして選び直します。
ソースの編集やモデルの変換をiPhone上で行う必要はありません。

## 4. ターミナルからWAVを生成する

リポジトリ直下で、手順1の配置のまま実行できます。

```sh
swift run -c release sbv2-say \
  models/sbv2-coreml-common/bert \
  models/sbv2-coreml-jvnv-f1-jp \
  models/sbv2-coreml-common/dictionary \
  output.wav "こんにちは。今日はいい天気ですね。"
afplay output.wav
```

`output.wav`はモノラル44.1 kHz、16 bit PCMです。任意で文章の後に`Happy 0`のようにスタイル名と話者IDを指定できます。
CLIはウォームアップを自動実行しません。表示される合成時間は初回推論の影響を含む場合があります。

## 初回だけ遅い場合

初回には、モデルのコンパイル、読み込み、初回推論の準備が発生します。
サンプルの「モデルを準備」はこの待ち時間を対話前にまとめるための操作です。
形状の異なる初回入力まで、すべて事前実行するものではありません。[実測値と条件](verification.ja.md)を参照してください。

## HTTPSでの取得は公開後に使う

Hugging Faceへ公開した各モデルの`download.json`のURLを、モデル設定の「URLからモデルを取得」に指定できます。
「取得するモデル」で共通モデルと声モデルを選び、別々に取得します。
リポジトリのWebページや`.tar.gz`のURLをこの欄に入れることはできません。
このURL経由の動作確認は、実際の公開先が決まってから行います。

困った場合は[トラブルシューティング](troubleshooting.ja.md)へ進んでください。
