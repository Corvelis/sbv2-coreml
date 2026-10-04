# Swift APIリファレンス

[ドキュメント一覧](README.ja.md) · [使用例](sdk-guide.ja.md)

対象は`SBV2CoreML`の公開API、バージョン`0.1.0.dev2`です。
宣言の原本は[SpeechSynthesizer.swift](../Sources/SBV2CoreML/SpeechSynthesizer.swift)、
[TextSegmenter.swift](../Sources/SBV2CoreML/TextSegmenter.swift)、
[ModelDownloader.swift](../Sources/SBV2CoreML/ModelDownloader.swift)です。
公開前のAPIで、今後変更する場合があります。

## ModelPaths

`init(bert: URL, voice: URL, dictionary: URL)`。3つの読み取り専用プロパティを持つ`Sendable`な構造体です。

| 引数 | 指定するフォルダ |
|---|---|
| `bert` | `vocab.txt`と`coreml_blocks/`がある場所 |
| `voice` | `config.json`、`style_vectors.npy`、`coreml_voice/`がある場所 |
| `dictionary` | `sys.dic`、`char.bin`、`matrix.bin`、`unk.dic`、`dicrc`がある場所 |

URLはローカル用です。BERTのキャッシュ作成先にも書き込めることが必要です。

## VoiceInfo

`init(directory: URL) throws`で声の`config.json`を読み取れます。`load`の戻り値でも取得できます。

| プロパティ | 型・内容 |
|---|---|
| `speakers` | `[String: Int]`。話者名から話者IDへの対応 |
| `styles` | `[String: Int]`。スタイル名からベクトルのインデックスへの対応 |
| `sampleRate` | `Int`。現在は44100 |

この初期化は設定の確認です。全モデルファイルの存在、ハッシュ、Core MLの読み込み成功を保証しません。
配布元のハッシュ検証と`SpeechSynthesizer.load`を併用してください。

## SpeechOptions

`init(speakerID: Int = 0, style: String = "Neutral", speed: Float = 1)`。
3つの値は変更可能です。

| プロパティ | 条件・意味 |
|---|---|
| `speakerID` | `VoiceInfo.speakers.values`に含まれるID |
| `style` | `VoiceInfo.styles`に存在する名前。大文字・小文字を含め一致させる |
| `speed` | 有限かつ0より大きい値。1が標準、1より大きいと短く速く、1より小さいと長く遅くなる |

すべての声に話者0や`Neutral`があるとは限りません。`warmUp`にも選択済みのオプションを渡します。
極端な速度指定はモデルのフレーム上限などに達する場合があります。
ノイズ強度、SDP比率、任意スタイル強度、計算デバイスを指定する公開オプションは現在ありません。

## SpeechSynthesizer

`init()`で作成します。初期化しただけではモデルを読み込みません。
内部の推論は専用の直列キューで実行し、MainActorを占有しない形で待機できます。
共有G2P状態があるため、複数インスタンスのネイティブ処理も同じキューで直列化されます。
複数インスタンスを作ってもTTSが並列に高速化される構成ではありません。

| メソッド | 戻り値 | 動作 |
|---|---|---|
| `load(_ paths: ModelPaths) async throws` | `VoiceInfo` | 既存の合成を無効化し、BERT・声・辞書を準備。既存モデルを再初期化する |
| `warmUp(options: SpeechOptions = .init()) async throws` | `Void` | 「こんにちは。」を実際に合成して破棄。モデル読み込み後に呼ぶ |
| `synthesize(_ text: String, options: SpeechOptions = .init()) async throws` | `SpeechChunk` | 内部で区間へ分割し、全区間のPCMを連結して返す |
| `stream(_ text: String, options: SpeechOptions = .init(), segmenter: TextSegmenter = .init())` | `SpeechStream` | 区間単位で取得するシーケンスを作る。作成だけでは推論しない |
| `cancel()` | `Void` | このインスタンスの既存ストリーム／合成を無効化する。モデルは保持する |
| `unload() async throws` | `Void` | 既存合成を無効化し、インスタンスのBERT・声モデルを解放する |

### 実行順と停止

- 同一インスタンスへの`load`、合成、`unload`はアプリ側で順序を管理してください。実行途中の声切り替えをトランザクションとして扱うAPIはありません。
- `load`に失敗したら、利用可能状態として扱わず、原因を直して再ロードしてください。
- `cancel()`の前に作ったストリームは再利用できません。次の発話では新しい`stream()`を作ります。
- `Task.cancel()`は区間取得などのキャンセル確認箇所で反映されます。処理中のCore ML予測を即座に中断する機能ではありません。
- `cancel()`はロード／コンパイルの中断や、再生済み・再生予約済み音声の停止を行いません。再生側も停止してください。
- 既にキャンセルされたTaskで`unload()`を呼ぶと、処理投入前のキャンセル確認で失敗し得ます。明示的な解放はキャンセルされていない管理Taskから行えます。
- インスタンス破棄時にもモデル解放をキューへ投入します。解放完了のタイミングを管理する場合は`unload`を待ちます。
- `unload`はディスクのモデル／キャッシュを削除しません。共有G2P辞書とOS側のキャッシュが残ることがあり、プロセスのRAMがゼロになる約束ではありません。

### 空文字と計測

空文字・空白だけの入力では区間がなく、`stream`は要素を返さず終了します。
`synthesize`は空PCM、長さ0秒を返します。この場合は推論が行われないため、モデルやオプションの検証も合成経路では実行されません。
画面では空入力を先に除外すると扱いやすくなります。

## SpeechStream / Iterator

`SpeechStream`は`AsyncSequence`で、要素は`SpeechChunk`です。
`makeAsyncIterator()`でイテレーターを作り、`next() async throws -> SpeechChunk?`で次の区間を要求します。
末尾は`nil`です。再生残量を待ってから`next()`すると、未再生PCMの蓄積を抑えられます。

全入力文字列の分割はシーケンス作成時に行います。生成途中のLLMトークンを追加するAPIではありません。
イテレーターを作り直すと最初から再合成します。PCMのリプレイキャッシュではありません。
モデル容量のエラーが出た区間は、句読点などの境界を優先して二分し、再試行します。必要なら文字間でも分割します。
再分割で解消しないエラーは呼び出し元へ返します。

## TextSegmenter

`init(maximumCharacters: Int = 250, allowFirstComma: Bool = true)`。
`maximumCharacters`は最低2に補正されます。両プロパティは読み取り専用です。
`split(_ text: String) -> [String]`はモデルを使わず、次の規則で文字列を区切ります。

- 句点・感嘆符・疑問符・改行：`。！？!?\n`
- 最初の区間のみ、`allowFirstComma`がtrueなら読点：`、,，`
- 境界がなければ`maximumCharacters`で強制分割。数え方はSwiftの`Character`単位です。
- 区間の前後の空白・改行を除去。空区間を除外し、句読点だけの末尾区間は前の区間へ付けます。

`synthesize`では既定値を使います。設定を変更する場合は`stream(..., segmenter: ...)`を使います。
250文字はモデルが一度に処理できる音素数とは異なります。128音素／512フレームなどの制約による再分割は別に発生します。

## SpeechChunk

SDKが返す`Sendable`な構造体です。利用者が任意のPCMから生成する公開イニシャライザーはありません。

| プロパティ／メソッド | 内容 |
|---|---|
| `text: String` | `stream`では処理した区間、`synthesize`では元の入力文字列 |
| `pcm: Data` | モノラルFloat32、リトルエンディアン。WAVヘッダーは含まない |
| `sampleRate: Int` | 44100 |
| `duration: Double` | PCMのサンプル数から計算した秒数 |
| `synthesisSeconds: Double` | 成功したネイティブ合成呼び出しの所要秒数。複数区間なら合計 |
| `rtf: Double` | `synthesisSeconds / max(duration, 0.000001)`。小さいほど速い |
| `capacitySplit: Bool` | モデル容量のため追加分割した区間でtrue。全文合成は1区間でも該当すればtrue |
| `wav() throws -> Data` | モノラル44.1 kHz・16 bit PCMのWAVを作る。有限でないPCM値はエラー |

通常の句点分割や250文字の強制分割だけでは`capacitySplit`はtrueになりません。
`synthesisSeconds`にはロード、別途行ったウォームアップ、キュー待機、容量超過で失敗した試行、再生時間を含めません。
画面操作からの待ち時間や厳密な全処理RTFは、呼び出し前後の壁時計時間も別に記録してください。
`synthesize`は全文のPCMをメモリへ保持するので、長文には`stream`を推奨します。

## ModelDownloader

`actor`です。`init()`後、次を呼びます。

`install(manifestURL: URL, destination: URL, progress: @Sendable (Int, Int) async -> Void = { _, _ in }) async throws`

| 引数 | 条件 |
|---|---|
| `manifestURL` | HTTPSの`download.json`。原本のAIVMやモデルのWebページは不可 |
| `destination` | まだ存在しないローカルのフォルダ。親フォルダは必要に応じ作成 |
| `progress` | 検証・保存が終わったファイル数と総ファイル数。バイト単位ではなく、MainActorでもない |

同階層の一時ディレクトリに順に取得し、各ファイルのサイズ・SHA-256を確認してから最終フォルダへ移します。
失敗時は一時ディレクトリを片付けます。既存フォルダを上書きせず、自動再開・自動更新・モデルの`load`も行いません。
更新する場合は別の新しいフォルダへ取得し、合成が止まってからアプリ側で使用先を切り替えます。
URLSession由来のネットワークエラー、JSONエラー、ファイルI/Oエラーもそのまま返ることがあります。

## DownloadManifest

`Codable, Sendable`。JSONからデコードできます。外部向けのメンバー指定イニシャライザーはありません。

| 型 | 読み取り専用プロパティ |
|---|---|
| `DownloadManifest` | `formatVersion: Int`、`name: String`、`files: [File]` |
| `DownloadManifest.File` | `path: String`、`sha256: String`、`bytes: Int64` |

対応バージョンは1、ファイル数は1〜10000、各サイズは0〜8 GiBです。
パスの空要素、`.`、`..`、バックスラッシュ、コロン、制御文字、重複エントリーを拒否します。
SHA-256は小文字16進64桁です。マニフェスト自体と配布元の信頼性は利用者が確認します。
[具体的なモデル仕様](model-format.ja.md)も参照してください。

## エラー

`SBV2Error`は`Error, LocalizedError`に準拠します。

| ケース | 意味 |
|---|---|
| `invalidModel(String)` | 設定・辞書・Core MLモデル・ダウンロードマニフェストなどの不備 |
| `synthesis(String)` | オプション不正、G2Pや推論の失敗、再分割でも解消しない容量超過など |
| `notLoaded` | 非空テキストを合成する前にロードが完了していない |
| `cancelled` | `cancel`や再ロードで合成要求が無効化された |

Swiftの`CancellationError`、FoundationのI/Oエラーなども返り得ます。
通常は`localizedDescription`を記録し、エラーの分類と併せて扱ってください。内部メッセージ文字列の完全一致をアプリの永続仕様にしないでください。
