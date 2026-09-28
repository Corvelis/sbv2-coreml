import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SBV2CoreML

@main struct SBV2DemoApp: App {
    var body: some Scene { WindowGroup { DemoView() } }
}

@MainActor final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var queuedSamples: Int64 = 0
    init() { engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: format) }
    var remaining: Double {
        guard let time = player.lastRenderTime, let played = player.playerTime(forNodeTime: time) else {
            return Double(queuedSamples) / 44100
        }
        return max(0, Double(queuedSamples - played.sampleTime) / 44100)
    }
    func append(_ chunk: SpeechChunk) throws {
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if !engine.isRunning { try engine.start() }
        let count = chunk.pcm.count / 4
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        chunk.pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: chunk.pcm.count))
        if let time = player.lastRenderTime, let played = player.playerTime(forNodeTime: time) {
            queuedSamples = max(queuedSamples, played.sampleTime)
        }
        player.scheduleBuffer(buffer)
        queuedSamples += Int64(count)
        if !player.isPlaying { player.play() }
    }
    func stop() { player.stop(); engine.stop(); queuedSamples = 0 }
}

@MainActor final class DemoState: ObservableObject {
    enum Asset: String, CaseIterable, Identifiable { case bert = "BERT", voice = "Voice", dictionary = "Dictionary"; var id: String { rawValue } }
    @Published var text = "こんにちは。今日はいい天気ですね。散歩に出かけてみましょう。"
    @Published var status = "BERT、声、辞書のフォルダを選択してください。"
    @Published var selectedStyle = "Neutral"
    @Published var selectedSpeaker = 0
    @Published var info: VoiceInfo?
    @Published var assets: [Asset: URL] = [:]
    @Published var busy = false
    @Published var ready = false
    @Published var downloadURL = ""
    @Published var downloadKind: Asset = .voice
    private let synthesizer = SpeechSynthesizer()
    private let player = PCMPlayer()
    private var task: Task<Void, Never>?
    private var scopedURLs: [URL] = []
    private var generation = 0
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    init() {
        // Files copied into the app's Documents directory work without an external bookmark.
        for (kind, name) in [(Asset.bert, "bert"), (.voice, "jvnv-f1-jp"), (.dictionary, "dictionary")] {
            let path = documents.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { assets[kind] = path }
        }
        for (kind, name) in [(Asset.bert, "sbv2-coreml-common/bert"),
                             (.dictionary, "sbv2-coreml-common/dictionary"), (.voice, "sbv2-coreml-jvnv-f1-jp")] {
            let path = documents.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path.path) { assets[kind] = path }
        }
        if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
            Task { await smokeTest() }
        }
    }
    func select(_ url: URL, kind: Asset) {
        stop()
        if url.startAccessingSecurityScopedResource() { scopedURLs.append(url) }
        assets[kind] = url
        if kind == .bert, FileManager.default.fileExists(atPath: url.appendingPathComponent("bert/vocab.txt").path) {
            assets[.bert] = url.appendingPathComponent("bert")
            assets[.dictionary] = url.appendingPathComponent("dictionary")
        }
        ready = false; info = nil
        status = "\(kind.rawValue): \(url.lastPathComponent)"
    }
    func prepare() {
        guard let bert = assets[.bert], let voice = assets[.voice], let dictionary = assets[.dictionary] else { return }
        stop(); generation += 1; let request = generation
        busy = true; ready = false; status = "モデルを準備しています。初回はコンパイルに時間がかかります。"
        task = Task {
            do {
                let start = ProcessInfo.processInfo.systemUptime
                let info = try await synthesizer.load(.init(bert: bert, voice: voice, dictionary: dictionary))
                try Task.checkCancellation()
                self.info = info
                selectedStyle = info.styles["Neutral"] != nil ? "Neutral" : info.styles.min { $0.value < $1.value }!.key
                selectedSpeaker = info.speakers.values.min()!
                try await synthesizer.warmUp(options: .init(speakerID: selectedSpeaker, style: selectedStyle))
                try Task.checkCancellation()
                ready = true
                status = String(format: "準備完了 %.1f秒", ProcessInfo.processInfo.systemUptime - start)
            } catch { if request == generation { status = error.localizedDescription } }
            if request == generation { busy = false }
        }
    }
    func speak() {
        stop(); busy = true
        generation += 1; let request = generation
        let input = text, options = SpeechOptions(speakerID: selectedSpeaker, style: selectedStyle)
        task = Task {
            do {
                let started = ProcessInfo.processInfo.systemUptime
                var first: Double?, totalAudio = 0.0, totalSynthesis = 0.0
                // Pull the next piece when two seconds of queued playback remain.
                var iterator = synthesizer.stream(input, options: options).makeAsyncIterator()
                while true {
                    while player.remaining > 2 {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    try Task.checkCancellation()
                    guard let chunk = try await iterator.next() else { break }
                    try Task.checkCancellation()
                    if first == nil { first = ProcessInfo.processInfo.systemUptime - started }
                    try player.append(chunk)
                    totalAudio += chunk.duration; totalSynthesis += chunk.synthesisSeconds
                    status = String(format: "最初のPCM %.2f秒 · RTF %.3f · 再生残り %.1f秒%@",
                        first!, totalSynthesis / max(totalAudio, 0.001), player.remaining,
                        chunk.capacitySplit ? " · モデル上限で分割" : "")
                }
                while player.remaining > 0.05 { try await Task.sleep(nanoseconds: 50_000_000) }
            } catch {
                if request == generation { status = error.localizedDescription }
            }
            if request == generation { busy = false }
        }
    }
    func stop() { generation += 1; task?.cancel(); task = nil; synthesizer.cancel(); player.stop(); busy = false }
    func download() {
        guard let url = URL(string: downloadURL), url.scheme == "https" else { status = "HTTPSのdownload.json URLを入力してください。"; return }
        let kind = downloadKind
        busy = true; status = "ダウンロード中…"
        task = Task {
            do {
                let destination = documents.appendingPathComponent("\(kind.rawValue.lowercased())-\(UUID().uuidString)")
                try await ModelDownloader().install(manifestURL: url, destination: destination) { done, total in
                    await MainActor.run { self.status = "取得・検証 \(done)/\(total)" }
                }
                assets[kind] = destination
                if kind == .bert, FileManager.default.fileExists(atPath: destination.appendingPathComponent("bert/vocab.txt").path) {
                    assets[.bert] = destination.appendingPathComponent("bert")
                    assets[.dictionary] = destination.appendingPathComponent("dictionary")
                }
                ready = false
                status = "取得完了: \(kind.rawValue)"
            } catch { status = error.localizedDescription }
            busy = false
        }
    }

    /// Reproducible on-device integration test using only explicitly supplied model folders.
    func smokeTest() async {
        busy = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        let base = ProcessInfo.processInfo.environment["SBV2_SMOKE_ROOT"].map { URL(fileURLWithPath: $0) } ?? documents
        let output = ProcessInfo.processInfo.environment["SBV2_SMOKE_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? documents
        let paths = ModelPaths(bert: base.appendingPathComponent("sbv2-coreml-common/bert"),
            voice: base.appendingPathComponent("sbv2-coreml-jvnv-f1-jp"),
            dictionary: base.appendingPathComponent("sbv2-coreml-common/dictionary"))
        var report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "inference": "Core ML", "voice": "jvnv-f1-jp", "status": "running"]
        var runs: [[String: Any]] = []
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await synthesizer.load(paths)
            report["loadSeconds"] = ProcessInfo.processInfo.systemUptime - started
            let cases = [("first", "こんにちは。", "Neutral"),
                ("normal1", "富士山は日本で一番高い山です。", "Neutral"),
                ("normal2", "富士山は日本で一番高い山です。", "Neutral"),
                ("sentences", "今日はいい天気ですね。散歩に出かけてみましょう。", "Neutral"),
                ("happy", "こんにちは。今日はいい天気ですね。", "Happy")]
            for (label, text, style) in cases {
                let start = ProcessInfo.processInfo.systemUptime
                let audio = try await synthesizer.synthesize(text, options: .init(style: style))
                let wall = ProcessInfo.processInfo.systemUptime - start
                runs.append(["case":label,"style":style,"audioSeconds":audio.duration,"wallSeconds":wall,
                    "rtf":wall / audio.duration,"capacitySplit":audio.capacitySplit,
                    "thermalState":ProcessInfo.processInfo.thermalState.rawValue])
                try audio.wav().write(to: output.appendingPathComponent("sbv2-\(label).wav"), options:.atomic)
            }
            report["status"] = "complete"
            status = "実機スモークテスト完了"
            try await synthesizer.unload()
        } catch { report["status"] = "failed"; report["error"] = error.localizedDescription; status = error.localizedDescription }
        report["runs"] = runs
        if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
            try? data.write(to:output.appendingPathComponent("sbv2-smoke.json"),options:.atomic)
        }
        busy = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}

struct DemoView: View {
    @StateObject private var state = DemoState()
    @State private var importing = false
    @State private var selectedAsset: DemoState.Asset = .bert
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("SBV2 Core ML").font(.title2.bold())
            Text("iPhone / Mac · JP-Extra · オフライン音声合成").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("モデル・辞書") {
                ForEach(DemoState.Asset.allCases) { kind in
                    HStack {
                        Button(kind.rawValue) { selectedAsset = kind; importing = true }.disabled(state.busy)
                        Text(state.assets[kind]?.lastPathComponent ?? "未選択").font(.caption).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Picker("取得する資産", selection: $state.downloadKind) { ForEach(DemoState.Asset.allCases) { Text($0.rawValue).tag($0) } }
                TextField("公開先の download.json URL", text: $state.downloadURL).textFieldStyle(.roundedBorder)
                Button("取得して検証", action: state.download).disabled(state.busy)
            }
            HStack {
                Button("準備・ウォームアップ", action: state.prepare).disabled(state.busy || state.assets.count != 3)
                if let info = state.info {
                    Picker("スタイル", selection: $state.selectedStyle) {
                        ForEach(info.styles.keys.sorted(), id: \.self) { Text($0).tag($0) }
                    }.disabled(state.busy)
                    if info.speakers.count > 1 {
                        Picker("話者", selection: $state.selectedSpeaker) {
                            ForEach(info.speakers.keys.sorted(), id: \.self) { Text($0).tag(info.speakers[$0]!) }
                        }.disabled(state.busy)
                    }
                }
            }
            TextEditor(text: $state.text).frame(minHeight: 180).border(.secondary.opacity(0.3))
            HStack {
                Button("読み上げ", action: state.speak).disabled(!state.ready || state.busy)
                Button("停止", action: state.stop)
            }
            Text(state.status).font(.caption).textSelection(.enabled)
            Text("コード: AGPL-3.0。音声・BERT・辞書にはそれぞれの利用条件が適用されます。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            do { state.select(try result.get(), kind: selectedAsset) }
            catch { state.status = error.localizedDescription }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 560)
        #endif
    }
}
