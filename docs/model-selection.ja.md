# INT8版と元のFP32版の選び方

[English](model-selection.md) · [クイックスタート](getting-started.ja.md) · [サンプルアプリ](sample-app.ja.md)

共通BERT・辞書は、**INT8版を`int8/`、元のFP32版を`float32/`**から取得します。
各フォルダにBERT・辞書・ライセンス・取得用マニフェストが揃っています。
どちらも同じSDKで使え、対応する声モデルをそのまま共有できます。声モデルを変換し直す必要はありません。

## どちらを使うか

| 比較 | INT8版 | 元のFP32版 |
|---|---|---|
| 選ぶ目安 | ファイル容量を抑えたい | BERTの重み量子化による数値差を避けたい、準備時間を短くしたい |
| 共通BERT・辞書の容量 | 約503 MB | 約1.52 GB |
| JVNVの声を含む合計 | 約797 MB | 約1.81 GB |
| BERTの重み | 32要素のブロック単位で8bit保存 | 量子化していない元のFP32重み |
| BERTの演算・入出力 | FP32 | FP32 |
| 再ロード後の準備時間の測定例 | 約18秒 | 約6秒 |
| 準備後のRTFの測定例 | 0.071 | 0.067 |

容量は配布ファイルの概算です。コンパイルキャッシュやダウンロード中の一時ファイルは別途必要です。
ファイル容量の削減率は、そのままRAMの削減率にはなりません。

時間はiPhone 17 Pro・JVNV Neutralを使った測定です。準備時間はコンパイル済みキャッシュがある状態の`load`＋`warmUp`、
RTFは3文を全文合成したときの中央値です。初回コンパイル、再生時間、LLMとの同時実行は含みません。
短い挨拶、別の文章・声・端末では値が変わります。INT8版が常に高速になるわけではありません。

INT8化で変えるのは共通BERTの重みです。声モデルの重みと辞書は変更しませんが、BERTの特徴量が変わることで
間・抑揚・音声の長さ・波形に差が生じる場合があります。JVNV Neutralの比較音声では聴き比べで気になる差はありませんでした。
採用する声と文章でも確認してください。FP32版もCore MLへの変換済みモデルであり、PyTorchの原本ではありません。

## サンプルアプリから取得する

**モデル設定 → URLからモデルを取得 → 取得するモデル：共通モデル**を開き、
**共通モデルの版**で**INT8（約503 MB）**または**FP32（約1.52 GB）**を選びます。
取得URLが自動設定されるので、**ダウンロード**を押します。
以下はファイル一式の版を固定したURLです。

### INT8版

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d/int8/download.json
```

### 元のFP32版

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d/float32/download.json
```

ファイル一覧も[INT8版](https://huggingface.co/AILogDev/sbv2-coreml-common/tree/973d6e239af305f0d78a8bf30c6af5093c0fd47d/int8)と[元のFP32版](https://huggingface.co/AILogDev/sbv2-coreml-common/tree/973d6e239af305f0d78a8bf30c6af5093c0fd47d/float32)に分かれています。
声モデルの取得先は両方で同じです。[JVNVの取得URL](getting-started.ja.md)を使うか、変換済みの自分の声フォルダを選びます。

## Macで取得する

[Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli)を使い、片方だけ取得します。
`--include`を省くと両版と互換用ファイルも取得されるため、そのまま指定してください。

**INT8版**

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "int8/*" --local-dir models
```

**元のFP32版**

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "float32/*" --local-dir models
```

INT8版の取得先は`models/int8/`、FP32版は`models/float32/`です。
既存のモデルフォルダに別の版を重ねず、各フォルダを丸ごと保持してください。
`.mlpackage`だけを差し替えると、ファイル一覧やチェックサムと一致しなくなります。

## 取得済みモデルを切り替える

### サンプルアプリ

1. 合成・再生を停止する。
2. **モデル設定 → 共通モデル**で、使う版の共通フォルダを選ぶ。`bert/`と`dictionary/`を含む親フォルダです。
3. 声モデルを選択したまま、**モデルを準備**を押す。

**共通モデル**のフォルダ表示には、メタデータにあるINT8／FP32の版も表示します。
**共通モデルの版**は取得先を選ぶ欄です。取得済みモデルを使うときは、選んだ共通フォルダで版が決まり、**モデルを準備**で読み込みます。
URL取得では毎回別フォルダへ保存し、完了したモデルを選択します。取得先はiPhoneの
**ファイル → このiPhone内 → SBV2 Core ML**から確認できます。
フォルダ選択はアプリ再起動後に必要に応じてやり直してください。

### SDK

`ModelPaths.bert`と`ModelPaths.dictionary`を、選んだ共通フォルダの`bert/`と`dictionary/`へ向けます。
`ModelPaths.voice`は同じ声フォルダを使います。`load`と`warmUp`は両方で共通です。
切り替えるときは合成Taskと再生を停止し、処理の終了を待ってから`load`、`warmUp`を順に実行します。
[SDKのモデル読み込み例](sdk-guide.ja.md)

## 容量を実際に減らすには

INT8版を追加しても、取得済みのFP32版やコンパイルキャッシュは自動削除されません。
使わない版を削除する場合は、アプリを終了するかSDKで`unload`し、その版の共通フォルダを削除します。
両方で使う声フォルダは保持してください。キャッシュの保存場所と扱いは[トラブルシューティング](troubleshooting.ja.md)を参照してください。

自分で共通BERTを圧縮する場合は[容量削減の手順](compression.ja.md)を参照してください。
