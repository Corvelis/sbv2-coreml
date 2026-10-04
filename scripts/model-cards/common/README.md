---
license: cc-by-sa-4.0
language: ja
tags: [coreml, style-bert-vits2]
base_model: ku-nlp/deberta-v2-large-japanese-char-wwm
---
# SBV2 Core ML 共通モデル・辞書

[English（補助）](README.en.md)

Style-Bert-VITS2 JP-ExtraをiPhone／Apple Silicon Macで使うための、共通BERTと日本語辞書です。
iOS 18以上、macOS 15以上のApple Siliconに対応するSwift SDK **SBV2CoreML**から使います。
一度取得すれば、互換性のある複数の声モデルで使い回せます。声モデルは別途取得してください。

## 出典と変換内容

- **BERT：** 京都大学の自然言語処理研究グループによる[DeBERTa日本語モデル](https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm)。原本の固定コミットは`547b0e8b044fba3f9b84d0ab9f990440bd130c8b`です。
- BERTを2つのFP32 Core ML ML Programへ変換しています。入力長の候補は64／128／256です。再学習・量子化は行っていません。
- 原本と変換済みBERTのライセンスは**CC BY-SA 4.0**です。`LICENSE.md`を参照してください。
- **辞書：** Open JTalk 1.11 UTF-8辞書です。Open JTalk／NAIST／UniDicの関係者によるBSD系の条件が別途適用されます。`dictionary/COPYING`を参照してください。

これは非公式の変換物です。原作者による承認・推奨を示すものではありません。

## 使い方

1. `.mlpackage`の中身を含め、このリポジトリのファイルをフォルダ構成のまま取得します。
2. 別配布の声モデルを用意します。
3. `ModelPaths`へBERTの`bert/`、辞書の`dictionary/`、声モデルのフォルダを渡します。

付属サンプルでは、この共通フォルダを**共通モデル**として選ぶとBERTと辞書を自動認識します。
Publicの場合は、固定コミットの`download.json` URLからも取得できます。
初回使用時には端末上でCore MLをコンパイルします。コンパイル済みキャッシュは配布物に含めていません。

`checksums.json`に配布ファイルのハッシュ、`provenance.json`に原本と変換内容を記録しています。
推論はモデルの取得後にオフラインで実行できます。
Swift SDK・サンプル・変換ツールのコードには、モデルとは別にAGPL-3.0が適用されます。
