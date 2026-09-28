# SBV2 Core ML 日本語ガイド

Style-Bert-VITS2 JP-ExtraをiPhone/Macで実行するための、独立したライブラリ・変換ツール・サンプルです。
対応はiOS 18以上、macOS 15以上のApple Silicon。アプリでの推論にFlutter・Python・ONNX Runtimeは不要です。

## 使うだけの場合

必要な配布フォルダは2つです。

- `sbv2-coreml-common`: 共通BERTと日本語辞書
- `sbv2-coreml-jvnv-f1-jp`: サンプル音声1種類

`Examples/Apple/SBV2Demo.xcodeproj`を開き、iPhoneなら`SBV2Demo-iOS`、Macなら
`SBV2Demo-macOS`を選んで実行します。iPhoneの署名チームとBundle IDは自分のものを指定してください。

アプリの「モデル・辞書」で共通フォルダをBERTとして指定すると、BERTと辞書を読み分けます。
音声フォルダをVoiceとして指定し、「準備・ウォームアップ」が終わったら読み上げられます。
Files/Finderからフォルダを渡すか、公開後の`download.json`のHTTPS URLから取得できます。

初回はCore MLのコンパイルが必要です。ダウンロード容量に加えてコンパイル用の空き容量が必要になります。
2回目以降はキャッシュを再利用します。読み込み・ウォームアップと音声合成の時間は別に測定します。

## 自分の声を変換する場合

```sh
python3.11 -m venv .venv
.venv/bin/python -m pip install './converter[convert]' -c converter/requirements-lock-macos-arm64.txt

# AivisHubから。AIVMの公開が必要です。
.venv/bin/sbv2-coreml convert --aivis-url https://hub.aivis-project.com/aivm-models/MODEL_UUID --output models/my-voice

# AIVMファイルから
.venv/bin/sbv2-coreml convert --aivm voice.aivm --output models/my-voice

# 自分で学習したモデルから
.venv/bin/sbv2-coreml convert --checkpoint model.safetensors --config config.json --styles style_vectors.npy --output models/my-voice
```

変換にはMac/Python 3.11を使います。SBV2のソースは固定版を自動取得します。
共通BERTを毎回変換する必要はありません。変換後のフォルダをVoiceとして選択すれば声を交換できます。

公開用アーカイブを作る場合は、元モデルのライセンスと出典も指定してください。
個人での変換と、変換後のモデルを他の人へ再配布できるかは別に判断します。
詳細は[変換手順](conversion.md)と[ライセンス](../THIRD_PARTY_NOTICES.md)を参照してください。

## 音声の区切り

句点・改行を優先し、最初の区間だけ読点も使います。句読点のない長文は250文字で強制分割します。
音素数や予測音声長の上限を超えた場合は、さらに区切り直します。その場合は`capacitySplit`で通知します。
サンプルは最初のPCMから再生を始め、再生残り約2秒で次の区間の合成を要求します。
LLMを同時実行する際の一時停止・再開は呼び出し元のアプリで接続してください。

## 現在の配布段階

ローカルの公開準備版です。公開先URLはリリース時に確定します。
動作確認と性能の範囲は[検証記録](verification.md)にまとめています。
すべての声・文章・機種で同じRTFや波形の完全一致を保証するものではありません。
