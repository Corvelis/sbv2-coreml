---
license: cc-by-sa-4.0
language: ja
pipeline_tag: text-to-speech
tags: [coreml, style-bert-vits2, jp-extra]
base_model: litagin/style_bert_vits2_jvnv
---
# JVNV F1 JP-Extra・Core ML音声モデル

[English（補助）](README.en.md)

iPhone／Apple Silicon MacのSwift SDK **SBV2CoreML**で使う、日本語の声モデル1種類です。
対応環境はiOS 18以上、macOS 15以上のApple Siliconです。
共通BERTとOpen JTalk辞書は別配布の共通パッケージから取得してください。

## 出典と変換内容

原本はlitagin氏の[Style-Bert-VITS2 JVNV](https://huggingface.co/litagin/style_bert_vits2_jvnv)に含まれる
`jvnv-F1-jp/jvnv-F1-jp_e160_s14000.safetensors`です。
固定コミットは`205830ca1d49e666ddfbf2a755f0108e9cade4dd`です。
[JVNVコーパス](https://sites.google.com/site/shinnosuketakamichi/research-topics/jvnv_corpus)を用いて学習されたモデルです。
原本とこの変換物のライセンスは**CC BY-SA 4.0**です。`LICENSE.md`を参照してください。

原本の重みから、Encoder／DP、SDP、文全体のFlow、波形DecoderをCore MLへ変換しています。
複数の入力形状で同一の重みを共有する多機能パッケージです。再学習・整数量子化は行っていません。
高速DecoderはFP32／FP16の混合精度を使い、比較用のFP32 Decoderも保持しています。
変換後の波形は元のPyTorch出力とビット単位で完全一致するものではありません。

これは非公式の変換物です。原作者による承認・推奨を示すものではありません。

## 使い方と対応範囲

このフォルダを`ModelPaths`の声モデルとして指定します。話者IDは`0`です。
スタイルは`Neutral`、`Angry`、`Disgust`、`Fear`、`Happy`、`Sad`、`Surprise`を使えます。
出力はモノラル44.1 kHzです。文章の区切りとモデル容量による分割はSwift SDKが処理します。
対応するのは互換性のある日本語JP-Extraモデルです。

`.mlpackage`の内部を含め、フォルダ全体を取得してください。
付属サンプルでは**声モデル**としてこのフォルダを選びます。
Publicの場合は、固定コミットの`download.json` URLからも取得できます。
初回には端末上でCore MLをコンパイルします。各配布ファイルのハッシュは`checksums.json`に記録しています。

## 検証状況

- `waveform_validation.json`：固定した合成入力で、FP32のニューラル処理全体とPyTorchを比較しています。
- `decoder_validation.json`：FP32と混合精度Decoderの数値誤差を分けて記録しています。
- `compaction_report.json`：多機能パッケージへまとめる前後の一致を確認しています。

2026-10-04の`0.1.0-dev1`の確認では、全7スタイルを含む自然文11ケースを比較しました。
原本FP32の声モデルに対するケース全体のSNRは46.05～47.01 dBで、音素の長さと出力サンプル数は一致しました。
この比較では前処理・BERT特徴・乱数入力を共有しており、それらを独立に比較した検査ではありません。

ユーザーは比較音声を一通り聴き、極まれなノイズはあるものの許容範囲と評価しました。
ノイズが出たケース・時刻・原本／Core MLのどちらかは特定されていません。
ノイズがないことや、すべての文章で知覚的な音質が完全一致することを示す結果ではありません。
実機の条件・速度・確認範囲は、コード側の日本語検証記録にまとめています。RTF 0.1は全条件での保証値ではありません。

コードと重みには別のライセンスが適用されます。Swift SDK・サンプル・変換ツールのコードはAGPL-3.0です。
