# モデル仕様 v1

[ドキュメント一覧](README.ja.md) · [English](model-format.md)

## 共通部分と声の分離

共通BERT・日本語辞書と声モデルを別々に保存します。声パッケージには、その声のEncoder／DP、SDP、Flow、Decoderとスタイルを含みます。
別のキャラクターの重みの一部分だけを混ぜず、変換した声パッケージ全体を交換します。

```text
sbv2-coreml-common/
  bert/vocab.txt
  bert/coreml_blocks/coreml_bert_blocks_manifest.json
  bert/coreml_blocks/prefix.0_enum-int8-b32.mlpackage/
  bert/coreml_blocks/group.1-23-conv_enum-int8-b32.mlpackage/
  dictionary/{char.bin,dicrc,matrix.bin,sys.dic,unk.dic,COPYING,...}
sbv2-coreml-jvnv-f1-jp/
  config.json
  style_vectors.npy
  coreml_voice/coreml_voice_blocks_manifest.json
  coreml_voice/voice_shared.mlpackage/
```

共通パッケージは約503 MB、JVNVの声は約294 MBです。これは展開後の配布ファイルで、RAMやコンパイル後のサイズではありません。

共通BERTの通常配布版は8bit重み保存・FP32演算のモデルです。
元のFP32版と、FP16保存版を作る方法は[容量削減の手順](compression.ja.md)に記載しています。

## 対応構造と上限

| 項目 | 対応値 |
|---|---|
| 系統 | 日本語Style-Bert-VITS2 JP-Extra、`add_blank=true` |
| サンプルレート／hop | 44100 Hz／512 |
| BERT | `deberta-v2-large-japanese-char-wwm-coreml-v1`、語彙22012、特徴1024次元 |
| BERT候補長 | 64／128／256トークン |
| スタイル | 256次元 |
| hidden／latent | 192チャンネル |
| 話者条件 | 512チャンネル |
| Text Encoder／SDP | 64／128音素。blankを含む実入力の最大128 |
| Flow | 64／128／256／512フレームから選択。区間全体を処理 |
| Decoder | 固定256／32フレームとFP32可変長参照版。文脈は左右13フレーム |
| upsample rates／kernels | `[8,8,2,2,2]`／`[16,16,8,2,2]` |
| upsample initial channel | 512 |
| ResBlock | `1`、kernels `[3,7,11]`、各dilations `[1,3,5]` |

Decoderの13フレームという値はこの構造に対するものです。任意の派生モデルへそのまま適用する仕様ではありません。
文章の250文字上限とモデルの音素数・予測音声長上限は独立しています。
大きな入力はSDKが追加分割し、`capacitySplit`で通知します。

声の多機能モデルは`pre_64`、`pre_128`、`sdp_64`、`sdp_128`、`flow_64`、`flow_128`、
`flow_256`、`flow_512`、`decoder_combined_flex`、`decoder_combined_len_256_fp16`、
`decoder_combined_len_32_fp16`を含みます。
`_fp16`は互換性のための関数名です。実際の精度は`decoder_validation.json`で確認します。

## 付属メタデータ

| ファイル | 用途 |
|---|---|
| `model.json` | 種別、形式版、構造、精度、必要な共通BERT、ライセンスIDなど |
| `provenance.json` | 原本の出典・ハッシュ・変換器の版・SBV2ソースの記録 |
| `LICENSE.md` | モデルの利用条件。共通辞書はさらに`dictionary/COPYING`を保持 |
| `checksums.json` | 相対ファイル名とSHA-256の対応 |
| `download.json` | HTTPS取得用のファイル一覧・サイズ・SHA-256 |
| `waveform_validation.json` | FP32のニューラル合成経路とPyTorchの比較 |
| `decoder_validation.json` | Decoderの精度、検証値、フォールバックの記録 |
| `compaction_report.json` | 多機能モデルにまとめる前後の比較 |

声の変換だけではHugging Face用のモデルカード／`download.json`は生成しません。
整合性確認に使うハッシュ一覧も、モデルの知覚的品質を保証するものではありません。

## download.json

次は構造の例です。ハッシュは説明用なのでダウンロードに使用できません。

```json
{
  "formatVersion": 1,
  "name": "example-voice",
  "files": [
    {"path": "config.json", "sha256": "0000000000000000000000000000000000000000000000000000000000000000", "bytes": 1234}
  ]
}
```

各ファイルのURLはマニフェストの隣を基準に解決します。配布する一覧には全モデル・設定・ライセンスとチェックサム一覧を含めます。
Hugging Faceでは変更されないコミット版の`resolve` URLを使い、途中でモデルとハッシュの版がずれないようにします。
HTTPS、サイズ、SHA-256、相対パスを確認してからインストールします。配布元とマニフェスト自体の信頼性は別に確認します。

## 保存先とキャッシュ

実行時はモデルと同じ階層に`.mlmodelc`を生成します。BERTの保存先は書き込み可能である必要があります。
Voiceローダーには一時コンパイル先へのフォールバックがありますが、アプリ全体では書き込み可能な保存領域を用意してください。
キャッシュは配布ハッシュ・アーカイブの対象外です。Macで作ったキャッシュをiPhoneの配布物へ混ぜないでください。
合成を止めて`unload`した後で削除できますが、次回は再コンパイルが必要です。

SDKはロード時に`checksums.json`全体を自動検証しません。取得時に`ModelDownloader`を使うか、ローカルファイルはCLIの`verify`で確認できます。
