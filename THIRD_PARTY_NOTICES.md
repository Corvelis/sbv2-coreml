# ライセンスと出典

[日本語ライセンスガイド](docs/licenses.ja.md) · [English（補助）](THIRD_PARTY_NOTICES.en.md)

## コード

このソース配布物と変更部分は**AGPL-3.0**で提供します。原文は`LICENSE`です。
Style-Bert-VITS2のモデル変換・日本語前処理の実装を含み、Swiftへの移植だけで元の利用条件がなくなるものではありません。
ライブラリ全体をクローズドソースへ組み込むための寛容なライセンスを、この配布物が別途付与するものではありません。
該当する場合の対応ソースの提供など、AGPLの条件を確認してください。

| 構成要素・作者 | 出典・条件 |
|---|---|
| Style-Bert-VITS2・litagin氏と貢献者 | [元リポジトリ](https://github.com/litagin02/Style-Bert-VITS2)、固定コミット`66de777e06392c0f313600be03c43ef96658b244`、AGPL-3.0。一部のユーザー辞書コードはLGPL-3.0で、原文を`LICENSES/SBV2-LGPL-3.0.txt`に保持しています。 |
| StackChan Talk／Local AIのネイティブ実装 | ローカルの元プロジェクトから抽出しました。Apache-2.0の表記を`LICENSES/LocalAI-Apache-2.0.txt`に保持し、抽出記録に元ファイルのハッシュを記載しています。組み合わせた配布物は既存の第三者表記を保ちAGPL-3.0で提供します。 |
| Open JTalk・HTS Working Group／名古屋工業大学 | BSD系条件。原文は`LICENSES/OpenJTalk-COPYING`、作者は`LICENSES/OpenJTalk-AUTHORS`です。 |
| MeCab・工藤拓氏／NTTと貢献者 | 同梱するBSD系条件は`LICENSES/OpenJTalk-mecab-COPYING`です。ソース内の原表記も保持しています。 |
| Transformers DeBERTa・Hugging Faceの貢献者 | [元リポジトリ](https://github.com/huggingface/transformers)、Apache-2.0。BERTエクスポーターでforward演算を使用・変更しています。原文は`LICENSES/Transformers-Apache-2.0.txt`です。 |
| Core ML Tools・Apple | [元リポジトリ](https://github.com/apple/coremltools)、BSD-3-Clause。Pythonの依存関係で、Swiftアプリには含めていません。原文を`LICENSES`に保持しています。 |
| PyTorch・貢献者 | BSD系条件。インストールするPython依存関係にはそれぞれのライセンスが適用されます。 |
| NumPy・NumPy開発者 | BSD-3-Clause。インストールするPython依存関係にはそれぞれのライセンスが適用されます。 |
| Safetensors・Hugging Face | Apache-2.0。インストールするPython依存関係にはそれぞれのライセンスが適用されます。 |

変更内容は、非同期Swiftラッパー、独立したパッケージ構成、文章・モデル容量に基づく分割、
取得時のハッシュ検証、サンプルアプリ、Decoderの直接変換、入力正規化、配布ツールです。
開始時点のファイルは`docs/source-inventory.json`に記録しています。
変換ツールが取得する上流ソースにも、その原表記を保持します。

## モデルと辞書

コードのライセンスは、取得する重み・データセットの条件を置き換えるものではありません。

| モデル・作者 | 出典・条件 |
|---|---|
| JVNV F1 JP-Extra・litagin氏 | [原モデル](https://huggingface.co/litagin/style_bert_vits2_jvnv)、固定コミット`205830ca1d49e666ddfbf2a755f0108e9cade4dd`。JVNVコーパスで学習されています。原本・変換済み重みはCC BY-SA 4.0で、原文は`LICENSES/CC-BY-SA-4.0.txt`です。 |
| 日本語DeBERTa・京都大学の自然言語処理研究グループ | [原モデル](https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm)、固定コミット`547b0e8b044fba3f9b84d0ab9f990440bd130c8b`、CC BY-SA 4.0。 |
| Open JTalk UTF-8辞書1.11・NAIST／UniDic Consortiumの貢献者 | `LICENSES/OpenJTalk-Dictionary.txt`と、辞書に同梱する元の`COPYING`を参照してください。取得元・ハッシュは`docs/dictionary-source.json`に記録しています。 |
| AivisHubの各モデル | 入力する各モデルの条件が適用されます。AIVMのライセンス文を保持します。ACML、ACML-NC、独自条件を同一のものとして扱わないでください。変換しても、再配布やキャラクター画像・ロゴ・名称の利用権が追加されるものではありません。 |

ソースGitには重み・コンパイル済みキャッシュを含めていません。
Hugging Face向けのモデルフォルダには、出典・原ライセンス・変換説明・ハッシュを保持します。
変換物は非公式で、原作者による承認・推奨を示すものではありません。

このページは日本語の案内です。ライセンスの原文は各ファイルに保持しています。
