[English](compression.md)

# 共通モデルの容量を減らす

`compress-common`は、取得済みの共通モデルのBERT重みを圧縮し、新しいフォルダへ保存します。
声モデルは別のまま使用します。再学習や元のBERTチェックポイントは必要ありません。
macOSと、変換ツールの`convert`依存パッケージが必要です。
インストール方法は[声モデルの変換](conversion.ja.md)を参照してください。

配布済みINT8版と元のFP32版を選んで使うだけなら変換は不要です。
[共通モデルの選び方・取得先・切り替え手順](model-selection.ja.md)を参照してください。
自分で圧縮し直す場合は、元のFP32版を取得します。

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "float32/*" --local-dir models
```

## 容量・速度の目安

| モデルファイル | FP32版 | 8bit版 | FP16保存版 |
|---|---:|---:|---:|
| 共通BERT・辞書 | 約1.52 GB | 約503 MB | 約815 MB |
| JVNVの声を含む合計 | 約1.81 GB | 約797 MB | 約1.11 GB |

配布ファイルのサイズです。実行時のコンパイルキャッシュは含みません。
iPhone 17 Pro・JVNV Neutralの3文合成では、準備後のRTF中央値がFP32版0.067、8bit版0.071でした。
短文や長文、別の声や端末では値が変わります。LLMなどを同時に実行した測定ではありません。

8bit版は共通BERTの初期準備に時間がかかります。
SDK v0.2.0での再ロード時の`load`＋`warmUp`は、この測定ではFP32版約6秒、8bit版約18秒でした。
初回コンパイルの時間はさらに別途必要です。
合成を繰り返すアプリでは、`load`と`warmUp`を準備時に実行し、そのインスタンスを保持してください。

## 8bit版を作る

```sh
.venv/bin/sbv2-coreml compress-common \
  --input models/float32 \
  --output models/my-common-int8 \
  --mode int8
.venv/bin/sbv2-coreml verify models/my-common-int8
```

32要素のブロックごとに重みを8bitで保存します。演算と入出力の精度はFP32を維持します。
既存の出力フォルダには上書きできません。入力には元の非圧縮共通モデルを指定してください。

## FP16保存版を自分で作る（任意）

FP16保存版の変換済みモデルは配布していません。`compress-common`で生成できます。

```sh
.venv/bin/sbv2-coreml compress-common \
  --input models/float32 \
  --output models/my-common-fp16 \
  --mode fp16-weights
```

こちらは大きな重みをFP16で保存し、FP32へ戻して計算します。
全演算をFP16に変える方式ではありません。8bit版より容量は大きくなり、速度も端末によって変わります。

## SDK・サンプルアプリで使う

サンプルアプリの「モデル設定 → 共通モデル」で、生成した共通モデルの親フォルダを選びます。
辞書も自動設定されます。声モデルの設定は同じものを使用できます。
SDKでは`ModelPaths.bert`と`ModelPaths.dictionary`に新しい共通モデルのサブフォルダを指定します。

圧縮は数値を丸めるため、声モデルの重みを変えなくても、読み方・間・音声波形が変わることがあります。
採用前に、使う声と文章で聴き比べ、対象端末で速度を確認してください。
ハッシュの検証は音質の評価を行いません。

生成物にはライセンス、出典、元のモデルカード、圧縮情報、新しい`checksums.json`と`download.json`が含まれます。
元モデルの利用条件は圧縮後も引き継がれます。
コンパイル済みの`.mlmodelc`キャッシュは含みません。初回準備時のコンパイル時間や、実行時のキャッシュ容量は別途必要です。
