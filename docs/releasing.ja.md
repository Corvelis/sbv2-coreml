# 公開手順

[ドキュメント一覧](README.ja.md) · [English](releasing.md)

対象はこのリポジトリを公開するメンテナーです。サンプルの利用者は[クイックスタート](getting-started.ja.md)へ進んでください。
各コマンドはローカルの準備用です。リモートリポジトリの作成・アップロードは自動実行しません。

## 配布先と確定する項目

| 公開先 | 内容 | 確定する情報 |
|---|---|---|
| GitHub | SDK、サンプル、変換コード、ドキュメント、ソースZIP | owner／repo、リリースタグ、ソースコミット |
| Hugging Face・共通 | BERT、辞書、モデルカード、ライセンス、ハッシュ | owner／repo、コミット版、download.json URL |
| Hugging Face・声 | JVNV F1 JP-Extra 1種類、同じ付属情報 | owner／repo、コミット版、download.json URL |

現在はこれらの公開先が未確定です。実在するURLが決まるまでは、ローカルからの利用手順を掲載します。
公開後の変更箇所は、ルートREADME、日本語README、クイックスタート、両方のモデルカードです。
モデルカードから実際のコードのタグへリンクし、コード側からモデルの固定コミットの取得先へリンクします。

## 1. コードとドキュメントを検証する

リポジトリ直下で実行します。Python環境は[変換ガイド](conversion.ja.md)に従って用意してください。

```sh
swift test
PYTHONPATH=converter .venv/bin/python -m unittest discover -s converter/tests -v
python3 scripts/check_docs.py --swift
xcodebuild -project Examples/Apple/SBV2Demo.xcodeproj -scheme SBV2Demo-macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/Apple/SBV2Demo.xcodeproj -scheme SBV2Demo-iOS \
  -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```

`--swift`付きのドキュメント確認は、SDKをビルドしてコード例を型チェックします。
リンクだけなら`python3 scripts/check_docs.py`を使えます。外部サイトへの接続検証はしません。
端末へ入れる際は、自分のTeamで署名して実機確認します。
Xcodeプロジェクトを再生成する場合のみ`/usr/bin/ruby scripts/generate_xcode_project.rb`と`xcodeproj` gemが必要です。

## 2. モデルを準備する

JVNV F1 JP-Extraの原本は、`litagin/style_bert_vits2_jvnv`のコミット
`205830ca1d49e666ddfbf2a755f0108e9cade4dd`の
`jvnv-F1-jp/jvnv-F1-jp_e160_s14000.safetensors`です。
原本の設定・スタイルも揃え、CC BY-SA 4.0の文と出典を指定して変換します。

`scripts/prepare_release.py`の入力は以下の4つです。

| 引数 | 入力 |
|---|---|
| `--bert` | 変換済みBERTのフォルダ。`vocab.txt`と`coreml_blocks/`を含む |
| `--voice` | JVNVの変換後の声フォルダ |
| `--dictionary` | Open JTalk UTF-8辞書1.11、COPYINGを含む原本一式 |
| `--bert-checkpoint` | 固定した元のHF BERT。`model.safetensors`を含む |

必要な入力を`input/`へ整理した場合の例です。`--output`には未作成の場所を指定します。

```sh
python3 scripts/prepare_release.py \
  --bert input/bert-coreml \
  --voice input/jvnv-f1-jp-coreml \
  --dictionary input/open_jtalk_dic_utf_8-1.11 \
  --bert-checkpoint input/bert-checkpoint \
  --output artifacts/huggingface
```

このレシピは固定したJVNV・BERT・辞書専用で、原本のハッシュを確認します。他の声にJVNVの名前やモデルカードを付けるためには使えません。
別の声を公開する場合は、その原本の許諾・出典・構造・検証結果を使い、専用のモデルカードを作成してください。

出力は`sbv2-coreml-common`と`sbv2-coreml-jvnv-f1-jp`です。
同一マシンでは不変の`.bin`重みをハードリンクして容量を節約する場合があります。リンクした重みをその場で編集しないでください。

## 3. 検聴と端末確認を行う

原本と変換後で自然文・スタイルを聴き比べます。長母音、無音、接続部、文末を含めて確認します。
数値誤差の基準を通ったことだけで知覚的品質の確認を置き換えないでください。
Decoderの窓と末尾補正は次のコマンドでも確認できます。

```sh
.venv/bin/python scripts/validate_decoder_windows.py \
  --voice artifacts/huggingface/sbv2-coreml-jvnv-f1-jp \
  --output artifacts/verification/jvnv-decoder-windows.json
```

記録には端末・OS・温度状態・精度・初回／ウォーム後の区別を入れます。[検証記録](verification.ja.md)を更新してください。
サンプルのDocumentsへ2つのモデルフォルダをコピーし、起動引数`--smoke-test`を付けると、5つのWAVと`sbv2-smoke.json`を生成します。
任意の環境変数`SBV2_TEST_SEED=20260928`で試験用乱数を固定できます。通常の利用では設定しません。
Macでは`SBV2_SMOKE_ROOT`に2フォルダの親、`SBV2_SMOKE_OUTPUT`に結果の出力先も指定できます。
この試験は音声をファイルへ出すもので、再生・ASR・LLMは含みません。

## 4. 配布するファイルを確定する

```sh
.venv/bin/sbv2-coreml verify artifacts/huggingface/sbv2-coreml-common
.venv/bin/sbv2-coreml verify artifacts/huggingface/sbv2-coreml-jvnv-f1-jp
.venv/bin/sbv2-coreml package \
  --input artifacts/huggingface/sbv2-coreml-jvnv-f1-jp \
  --output artifacts/releases/sbv2-coreml-jvnv-f1-jp-0.1.0-dev1.tar.gz
```

アーカイブは新しい名前で作ります。出力済みの同名ファイルを上書きしません。
Hugging Faceには`checksums.json`に列挙した資産と、`checksums.json`、`download.json`、`.gitattributes`をアップロードします。
ローカル検証で生成された`.mlmodelc`をフォルダごと誤ってアップロードしないでください。
`package`のtar.gzにはハッシュに列挙された資産と`checksums.json`を含めます。`download.json`は直接HTTPSで配るフォルダ側に置きます。

モデルカードや出典を書き換えた場合は、`scripts/prepare_release.py`の`seal`関数で対象フォルダのハッシュ一覧とダウンロード一覧を再生成し、再検証します。
未確認の取得物を単に再sealして正常扱いする用途には使いません。元モデルの検証後に、意図したメタデータ更新だけを反映します。

## 5. 公開と公開URLの確認

1. GitHubへこの独立リポジトリを公開し、版をタグ付けする。大きなモデル、キャッシュ、原本、個人の署名情報はコミットしない。
2. Hugging Faceへ共通資産と声をそれぞれ公開し、コードのタグへのリンク、原作者・原本・利用条件・変更内容を保持する。
3. 公開したコミットを記録し、各`download.json`を固定コミットのHTTPS URLで参照する。
4. 初期状態のサンプルアプリで2つのマニフェストから取得し、準備・合成・再起動後の再利用を確認する。
5. READMEとモデルカードの公開先情報を確定し、リリースノートへ確認した条件と制限を記載する。

サンプルのURL取得では生成したフォルダのパスを実行中に保持します。現在はその選択をアプリ再起動後へ自動保存する実装ではありません。
再起動後は取得済みフォルダを再選択できます。製品アプリでは選択パス・版・必要なアクセス権を永続化してください。

コードのSDK化やバイナリ化でライセンス条件は変わりません。[ライセンスと出典](licenses.ja.md)を確認し、
配布するアプリの条件に合わせて判断してください。この手順はApp Storeでの配布適合性を検証した記録ではありません。
