# SDK導入・実装ガイド

[ドキュメント一覧](README.ja.md) · [APIリファレンス](api-reference.ja.md)

## Xcodeへ追加する

1. iOSまたはmacOSのアプリプロジェクトを開く。
2. Deployment TargetをiOS 18以上、またはmacOS 15以上にする。Macの対象はApple Siliconです。
3. **File → Add Package Dependencies → Add Local**で、このリポジトリの`Package.swift`があるフォルダを選ぶ。
4. Package Product **SBV2CoreML**をアプリのターゲットへ追加する。CLI用の`sbv2-say`をリンクする必要はありません。
5. アプリのSwiftファイルに`import SBV2CoreML`を書く。

GitHub公開後は手順3で公開リポジトリのURLとリリース版を選べます。現在はローカル追加を使用します。
操作は[Appleのローカルパッケージ追加手順](https://developer.apple.com/documentation/xcode/editing-a-package-dependency-as-a-local-package)に対応しています。

## モデルの保存場所

モデルをアプリの書き込み可能なDocumentsまたはApplication Supportへ配置します。
`ModelPaths`には**ローカルのフォルダURL**を渡します。HTTPS URLや個々の`.mlpackage`を直接渡しません。
共通フォルダの`bert/`と`dictionary/`、声フォルダのルートをそれぞれ指定します。

現在のBERT実装は`.mlpackage`と同じ階層に`.mlmodelc`キャッシュを保存するため、そこへの書き込み権限が必要です。
アプリの読み取り専用Bundleに同梱した場合は、初回に書き込み可能な領域へコピーしてから読み込んでください。

Files/Finderのピッカーから外部フォルダを受け取った場合は、セキュリティスコープを開いてアプリ内へコピーする方法が扱いやすくなります。
外部フォルダをそのまま使う場合は、モデル使用中のアクセス権を保持し、使用後に対応する解放処理を行います。
URLのパス文字列を保存するだけでは外部フォルダへの権限は復元できません。[Appleの説明](https://developer.apple.com/documentation/foundation/nsurl/)

付属サンプルではDocuments直下の`sbv2-coreml-common`と`sbv2-coreml-jvnv-f1-jp`を自動検出します。
自分のiPhoneアプリでDocumentsをFiles／Finderの共有対象にする場合は、用途に合わせて
`UIFileSharingEnabled`と`LSSupportsOpeningDocumentsInPlace`を設定してください。
[Appleのファイル共有の説明](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled)

## 最初の音声を作る

次の関数をアプリへコピーできます。引数は読み書き可能なローカルURLです。
サンプル声以外にも対応するよう、実際の話者とスタイルをモデル情報から選びます。

```swift
import Foundation
import SBV2CoreML

func writeGreeting(common: URL, voice: URL, output: URL) async throws {
    let speech = SpeechSynthesizer()
    do {
        let info = try await speech.load(ModelPaths(
            bert: common.appendingPathComponent("bert"),
            voice: voice,
            dictionary: common.appendingPathComponent("dictionary")))
        guard let speaker = info.speakers.values.min(),
              let style = info.styles["Neutral"] != nil
                ? "Neutral" : info.styles.min(by: { $0.value < $1.value })?.key else {
            throw SBV2Error.invalidModel("話者またはスタイルがありません")
        }
        let options = SpeechOptions(speakerID: speaker, style: style, speed: 1)
        try await speech.warmUp(options: options)
        let audio = try await speech.synthesize("こんにちは。", options: options)
        try audio.wav().write(to: output, options: .atomic)
        try await speech.unload()
    } catch {
        speech.cancel()
        throw error
    }
}
```

Documentsへ2フォルダをコピー済みなら、SwiftUIのボタンなどから次の関数を`Task`内で呼べます。
エラー表示は呼び出し元の画面で行ってください。出力先の親フォルダはあらかじめ存在する必要があります。

```swift
import Foundation

func writeGreetingInDocuments() async throws -> URL {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let output = documents.appendingPathComponent("greeting.wav")
    try await writeGreeting(
        common: documents.appendingPathComponent("sbv2-coreml-common"),
        voice: documents.appendingPathComponent("sbv2-coreml-jvnv-f1-jp"),
        output: output)
    return output
}
```

これは1回のWAV生成の例です。チャットでは画面やサービスが`SpeechSynthesizer`を保持し、
`load`と`warmUp`を準備時に行い、文章ごとには`synthesize`または`stream`だけを呼びます。
入力は日本語の本文です。SDKにMarkdown除去やLLMの出力整形を任せるAPIはありません。

## 擬似ストリーミングと再生

`stream`は、渡された文章を区間へ分割して返す`AsyncSequence`です。LLMの未確定トークンを継ぎ足すAPIではありません。
LLM側で読み上げ可能な文章を確定し、SDKへ渡します。

```swift
import Foundation
import SBV2CoreML

func forwardSpeech(
    speech: SpeechSynthesizer,
    text: String,
    options: SpeechOptions,
    waitForPlaybackCapacity: () async throws -> Void,
    enqueuePCM: (SpeechChunk) async throws -> Void
) async throws {
    var iterator = speech.stream(text, options: options).makeAsyncIterator()
    while true {
        try await waitForPlaybackCapacity()
        try Task.checkCancellation()
        guard let chunk = try await iterator.next() else { break }
        try await enqueuePCM(chunk)
    }
}
```

`waitForPlaybackCapacity`は、アプリが持つ再生キューに空きができるまで待つ処理です。
付属[PCMPlayerとDemoState](../Examples/Apple/SBV2Demo.swift)は、再生残りが約2秒以下になったら次の`next()`を呼びます。
再生前は待ち時間を入れず最初の区間を要求し、届いたPCMをすぐキューへ追加します。
これは区間単位の先行再生です。各区間内のDecoder窓ごとにPCMを返すAPIではありません。

PCMはFloat32・モノラル・44.1 kHzです。`wav()`は16 bit PCM WAVへ変換します。
SDK自体はスピーカーへ再生しません。AVAudioEngineなどの再生処理と、iOSのAVAudioSession管理はアプリ側で行います。
会話全文のPCMを保持せず、再生済みのバッファを解放してください。

LLMと併用する場合の優先順位は呼び出し元で制御します。

1. 最初に読める文章が確定するまではLLMを進める。
2. 最初のTTSを合成して再生キューへ入れる間は、LLMを安全な境界で待機させる。
3. 再生中はLLMを再開し、次の確定文を用意する。
4. 再生残り約2秒で次のTTSを要求する。合成時間に応じて余裕を調整する。

SDKにはllama.cpp／LiteRT-LMの停止・再開接続は含まれていません。
2秒という閾値だけで、すべての機種・モデル・同時負荷で途切れないことを保証するものではありません。
読み上げ区間を別々の`stream()`へ渡す場合、最初の読点分割の状態は呼び出しごとにリセットされます。
2回目以降は`TextSegmenter(allowFirstComma: false)`を指定すると、会話側の方針と揃えられます。

## 停止と声の切り替え

停止時は合成を開始した`Task`の`cancel()`、`speech.cancel()`、再生プレイヤーの停止を行います。
処理中のCore ML呼び出しは完了を待ちます。UIではTaskの終了を待ってから次の処理を開始すると、古い結果の表示を避けられます。
`cancel()`だけでは既に再生キューへ渡した音声を止めません。

声の切り替えは、合成Taskを止めた後、同じ共通モデルのURLと新しい声のURLで`load`し、返された話者・スタイルを選んで`warmUp`します。
共通ファイルの再取得は不要ですが、現在の`load`はモデルを再初期化します。BERTをRAMへ保持したまま声だけ差し替えるAPIではありません。
同一インスタンスで`load`、合成、`unload`を並行して開始せず、アプリ側で順番を管理してください。

## 公開後のモデルダウンロード

```swift
import Foundation
import SBV2CoreML

func downloadModel(manifestURL: URL, newDirectory: URL) async throws {
    try await ModelDownloader().install(
        manifestURL: manifestURL,
        destination: newDirectory
    ) { completedFiles, totalFiles in
        print("取得済みファイル: \(completedFiles)/\(totalFiles)")
    }
}
```

`manifestURL`には配布者が公開した**HTTPSのdownload.json URL**を渡します。公開先はまだ未確定です。
`newDirectory`は未作成の出力先にします。アプリがインストール済みモデルのパス・版を保持し、再起動時はそのパスを再利用します。
SDKは自動更新、再開ダウンロード、既存フォルダへの上書きは行いません。
コールバックはMainActorとは限りません。UI更新は`await MainActor.run { ... }`で行ってください。

## ライフサイクルの目安

```text
アプリ準備 → ファイル取得／配置 → load → warmUp → 利用可能
利用中     → stream／synthesize → PCMを再生
停止       → Task.cancel＋speech.cancel＋再生停止 → Task終了待ち
終了       → unload → 必要ならディスク上の資産を管理
```

モデルはSDKが勝手に削除しません。キャッシュの扱い、メモリ解放の範囲は
[APIリファレンス](api-reference.ja.md)と[トラブルシューティング](troubleshooting.ja.md)を参照してください。
