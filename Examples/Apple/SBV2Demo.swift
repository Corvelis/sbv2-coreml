import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import SBV2CoreML

@main struct SBV2DemoApp: App {
    var body: some Scene { WindowGroup { DemoView() } }
}

/// Plays one complete Float32 buffer after synthesis has finished.
@MainActor final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var samples: Int64 = 0
    private var generation = 0
    private(set) var isPlaying = false
    init() { engine.attach(node); engine.connect(node, to: engine.mainMixerNode, format: format) }
    var progress: Double {
        guard samples > 0, let time = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: time) else { return 0 }
        return min(1, max(0, Double(played.sampleTime) / Double(samples)))
    }
    func play(_ audio: SpeechChunk) throws {
        stop()
        #if os(iOS)
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        let count = audio.pcm.count / MemoryLayout<Float>.stride
        guard count > 0, count <= Int(UInt32.max),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else {
            throw SBV2Error.synthesis("音声を再生できませんでした。")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        audio.pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: channel, count: audio.pcm.count))
        try engine.start()
        samples = Int64(count)
        let request = generation
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == request else { return }
                self.isPlaying = false
                self.node.stop()
                self.engine.stop()
            }
        }
        isPlaying = true
        node.play()
    }
    func stop() { generation += 1; node.stop(); engine.stop(); samples = 0; isPlaying = false }
}

@MainActor final class DemoState: ObservableObject {
    enum Asset: String, CaseIterable, Identifiable { case bert = "BERT", voice = "Voice", dictionary = "Dictionary"; var id: String { rawValue } }
    enum CommonDownload: String, CaseIterable, Identifiable {
        case int8 = "INT8（約503 MB）", float32 = "FP32（約1.52 GB）", custom = "カスタムURL"
        var id: String { rawValue }
        var manifestURL: String {
            let base = "https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d"
            switch self {
            case .int8: return base + "/int8/download.json"
            case .float32: return base + "/float32/download.json"
            case .custom: return ""
            }
        }
    }
    private static let sampleVoiceURL = "https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp/resolve/17faac326f120b171170f10807bb26b0da8257d9/download.json"
    enum Phase: Equatable { case idle, preparing, generating, playing, downloading, ready, failed }
    struct Metrics {
        let synthesisSeconds: Double
        let audioSeconds: Double
        let capacitySplit: Bool
        var rtf: Double { synthesisSeconds / max(audioSeconds, 0.001) }
    }
    @Published var phase: Phase = .idle
    @Published var metrics: Metrics?
    @Published var playbackProgress = 0.0
    @Published var text = "こんにちは。今日はいい天気ですね。散歩に出かけてみましょう。"
    @Published var status = "BERT、声、辞書のフォルダを選択してください。"
    @Published var selectedStyle = "Neutral"
    @Published var selectedSpeaker = 0
    @Published var info: VoiceInfo?
    @Published var assets: [Asset: URL] = [:]
    @Published var busy = false
    @Published var ready = false
    @Published var downloadURL = CommonDownload.int8.manifestURL
    @Published var downloadKind: Asset = .bert
    @Published var commonDownload: CommonDownload = .int8
    private let synthesizer = SpeechSynthesizer()
    private let player = AudioPlayer()
    private var lastAudio: SpeechChunk?
    private var timing: [String: Double] = [:]
    var canReplay: Bool { lastAudio != nil && !busy }
    var voiceName: String { info?.speakers.keys.sorted().first ?? "声モデルを選択" }
    var commonModelLabel: String {
        guard let bert = assets[.bert] else { return "未選択" }
        let root = bert.lastPathComponent == "bert" ? bert.deletingLastPathComponent() : bert
        guard let data = try? Data(contentsOf: root.appendingPathComponent("model.json")),
              let model = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              model["kind"] as? String == "common" else { return root.lastPathComponent }
        let precision: String
        switch model["bert_weight_storage"] as? String {
        case "int8": precision = "INT8"
        case "float32", nil: precision = "FP32"
        case "fp16-weights": precision = "FP16保存"
        default: precision = "カスタム"
        }
        return "\(precision) · \(root.lastPathComponent)"
    }
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
        if ProcessInfo.processInfo.arguments.contains("--sample-check") {
            Task { await sampleCheck() }
        } else if ProcessInfo.processInfo.arguments.contains("--smoke-test") {
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
        ready = false; info = nil; metrics = nil; lastAudio = nil; phase = .idle
        status = "\(kind.rawValue): \(url.lastPathComponent)"
    }
    func prepare() {
        guard let bert = assets[.bert], let voice = assets[.voice], let dictionary = assets[.dictionary] else { return }
        stop(); generation += 1; let request = generation
        busy = true; ready = false; phase = .preparing; status = "モデルを準備しています。初回は少し時間がかかります。"
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
                ready = true; phase = .ready
                status = String(format: "準備完了 %.1f秒", ProcessInfo.processInfo.systemUptime - start)
            } catch { if request == generation { phase = .failed; status = error.localizedDescription } }
            if request == generation { busy = false }
        }
    }
    func speak() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "読み上げたい文章を入力してください。"; return
        }
        guard ready else { return }
        stop(); busy = true; phase = .generating; metrics = nil; playbackProgress = 0
        status = "音声を生成しています。"
        let request = generation
        let input = text, options = SpeechOptions(speakerID: selectedSpeaker, style: selectedStyle)
        task = Task {
            do {
                let started = ProcessInfo.processInfo.systemUptime
                // Return the complete utterance before starting playback.
                let audio = try await synthesizer.synthesize(input, options: options)
                try Task.checkCancellation()
                guard request == generation else { return }
                let completed = ProcessInfo.processInfo.systemUptime
                guard !audio.pcm.isEmpty else { throw SBV2Error.synthesis("音声を生成できませんでした。") }
                lastAudio = audio
                metrics = Metrics(synthesisSeconds: completed - started, audioSeconds: audio.duration,
                    capacitySplit: audio.capacitySplit)
                timing = ["synthesisStarted": started, "synthesisCompleted": completed]
                try await play(audio, request: request)
            } catch {
                if request == generation { phase = .failed; status = error.localizedDescription; player.stop() }
            }
            if request == generation { busy = false }
        }
    }
    private func play(_ audio: SpeechChunk, request: Int) async throws {
        try Task.checkCancellation()
        timing["playbackStarted"] = ProcessInfo.processInfo.systemUptime
        try player.play(audio)
        phase = .playing; status = "再生中"; playbackProgress = 0
        while player.isPlaying {
            try await Task.sleep(nanoseconds: 100_000_000)
            try Task.checkCancellation()
            guard request == generation else { return }
            playbackProgress = player.progress
        }
        try Task.checkCancellation()
        guard request == generation else { return }
        playbackProgress = 1; phase = .ready; status = "再生完了"
        timing["playbackCompleted"] = ProcessInfo.processInfo.systemUptime
    }
    func replay() {
        guard let audio = lastAudio, !busy else { return }
        stop(); busy = true
        let request = generation
        task = Task {
            do { try await play(audio, request: request) }
            catch { if request == generation { phase = .failed; status = error.localizedDescription } }
            if request == generation { busy = false }
        }
    }
    func stop() {
        generation += 1; task?.cancel(); task = nil; synthesizer.cancel(); player.stop(); busy = false
        playbackProgress = 0; phase = ready ? .ready : .idle; status = "停止しました。"
    }
    func chooseDownloadKind(_ kind: Asset) {
        downloadKind = kind
        downloadURL = kind == .bert ? commonDownload.manifestURL : Self.sampleVoiceURL
    }
    func chooseCommonDownload(_ preset: CommonDownload) {
        commonDownload = preset
        downloadURL = preset.manifestURL
    }
    func editDownloadURL(_ value: String) {
        downloadURL = value
        if downloadKind == .bert {
            commonDownload = CommonDownload.allCases.first { $0.manifestURL == value } ?? .custom
        }
    }
    func download() {
        guard let url = URL(string: downloadURL), url.scheme == "https" else { status = "HTTPSのdownload.json URLを入力してください。"; return }
        stop(); let request = generation
        let kind = downloadKind
        busy = true; phase = .downloading; status = "ダウンロード中…"
        task = Task {
            do {
                let destination = documents.appendingPathComponent("\(kind.rawValue.lowercased())-\(UUID().uuidString)")
                try await ModelDownloader().install(manifestURL: url, destination: destination) { done, total in
                    await MainActor.run { if request == self.generation { self.status = "取得・検証 \(done)/\(total)" } }
                }
                try Task.checkCancellation()
                guard request == generation else { return }
                assets[kind] = destination
                if kind == .bert, FileManager.default.fileExists(atPath: destination.appendingPathComponent("bert/vocab.txt").path) {
                    assets[.bert] = destination.appendingPathComponent("bert")
                    assets[.dictionary] = destination.appendingPathComponent("dictionary")
                }
                ready = false; info = nil; lastAudio = nil; metrics = nil; phase = .idle
                status = "取得完了: \(kind.rawValue)"
            } catch { if request == generation { phase = .failed; status = error.localizedDescription } }
            if request == generation { busy = false }
        }
    }

    /// Runs the production sample controller and audio player without UI automation or mirroring.
    func sampleCheck() async {
        let base = ProcessInfo.processInfo.environment["SBV2_SMOKE_ROOT"].map { URL(fileURLWithPath: $0) } ?? documents
        let output = ProcessInfo.processInfo.environment["SBV2_SMOKE_OUTPUT"].map { URL(fileURLWithPath: $0) } ?? documents
        var report: [String: Any] = ["os": ProcessInfo.processInfo.operatingSystemVersionString,
            "voice": "jvnv-f1-jp", "playbackMode": "complete utterance, single Float32 buffer",
            "strategy": "production DemoState and AudioPlayer, no UI automation", "status": "running"]
        var runs: [[String: Any]] = []
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        func waitForCompletion() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 180
            while busy {
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    stop(); throw SBV2Error.synthesis("Sample operation timed out")
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard phase != .failed else { throw SBV2Error.synthesis(status) }
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            select(base.appendingPathComponent("sbv2-coreml-common"), kind: .bert)
            select(base.appendingPathComponent("sbv2-coreml-jvnv-f1-jp"), kind: .voice)
            guard assets.count == 3 else { throw SBV2Error.invalidModel("Common model/dictionary not detected") }
            let started = ProcessInfo.processInfo.systemUptime
            prepare(); try await waitForCompletion()
            guard ready, let info else { throw SBV2Error.notLoaded }
            report["preparationSeconds"] = ProcessInfo.processInfo.systemUptime - started
            var cases = info.styles.keys.sorted().map { ($0.lowercased(), "富士山は日本で一番高い山です。", $0) }
            cases += [("sentences", "こんにちは。今日はいい天気ですね。散歩に出かけてみましょう。", "Neutral"),
                ("long", "今日は朝から公園を歩いてから駅の近くにある小さな喫茶店で温かいコーヒーを飲んで午後には図書館で旅行の本を読みながら次の休みに行ってみたい場所をゆっくり考えて夕方になったら家に帰って夕食を作ろうと思っています。", "Neutral"),
                ("short", "こんにちは。", "Neutral")]
            for (label, input, style) in cases {
                text = input; selectedStyle = style
                speak(); try await waitForCompletion()
                guard let audio = lastAudio, let metrics, timing["synthesisCompleted"] != nil,
                      let playback = timing["playbackStarted"], let synthesis = timing["synthesisCompleted"],
                      playback >= synthesis, phase == .ready, !player.isPlaying, playbackProgress == 1 else {
                    throw SBV2Error.synthesis("Playback did not complete after full synthesis")
                }
                try audio.wav().write(to: output.appendingPathComponent("sample-\(label).wav"), options: .atomic)
                runs.append(["case": label, "style": style, "text": input,
                    "synthesisSeconds": metrics.synthesisSeconds, "audioSeconds": metrics.audioSeconds,
                    "rtf": metrics.rtf, "capacitySplit": audio.capacitySplit,
                    "timing": timing, "playbackCompleted": true,
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue])
            }
            replay(); try await waitForCompletion()
            report["replayCompleted"] = phase == .ready && playbackProgress == 1
            replay(); try await Task.sleep(nanoseconds: 150_000_000)
            stop()
            guard !busy, !player.isPlaying, status == "停止しました。" else {
                throw SBV2Error.synthesis("Stop did not stop the sample player")
            }
            report["stopPassed"] = true
            report["status"] = "complete"; status = "実機確認完了"; phase = .ready
        } catch {
            report["status"] = "failed"; report["error"] = error.localizedDescription
            stop(); phase = .failed; status = error.localizedDescription
        }
        report["runs"] = runs
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("sbv2-sample-check.json"), options: .atomic)
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

private enum DemoStyle {
    static let accent = Color(red: 0.12, green: 0.48, blue: 0.44)
    static let background = Color.primary.opacity(0.035)
    static let names = ["Neutral": "標準", "Happy": "うれしい", "Sad": "悲しい", "Angry": "怒り",
                        "Fear": "不安", "Disgust": "嫌悪", "Surprise": "驚き"]
}

struct DemoView: View {
    @StateObject private var state = DemoState()
    @State private var showingModels = false
    @FocusState private var editing: Bool

    private var actionTitle: String {
        if state.busy {
            switch state.phase {
            case .preparing: return "準備中…"
            case .playing: return "再生中"
            case .downloading: return "取得中…"
            default: return "生成中…"
            }
        }
        if state.assets.count != 3 { return "モデルを選ぶ" }
        return state.ready ? "生成して再生" : "モデルを準備"
    }
    private var statusSymbol: String {
        switch state.phase {
        case .ready: return "checkmark.circle.fill"
        case .playing: return "speaker.wave.2.fill"
        case .failed: return "exclamationmark.circle"
        default: return "circle"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").font(.title3.weight(.semibold))
                    .foregroundStyle(DemoStyle.accent)
                    .frame(width: 42, height: 42)
                    .background(DemoStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text("音声をつくる").font(.title3.weight(.semibold))
                    Text("Style-Bert-VITS2 · Core ML").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { editing = false; showingModels = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.body.weight(.medium)).frame(width: 38, height: 38)
                }
                .buttonStyle(.plain).background(DemoStyle.background, in: Circle())
                .accessibilityLabel("モデル設定").accessibilityIdentifier("modelSettings").help("モデル設定").disabled(state.busy)
            }.frame(maxWidth: 640).padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 18)
                .frame(maxWidth: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(state.voiceName, systemImage: "person.wave.2")
                                .font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            if let info = state.info {
                                Picker("スタイル", selection: $state.selectedStyle) {
                                    ForEach(info.styles.keys.sorted(), id: \.self) {
                                        Text(DemoStyle.names[$0] ?? $0).tag($0)
                                    }
                                }.labelsHidden().pickerStyle(.menu).disabled(state.busy)
                                    .accessibilityLabel("スタイル").accessibilityIdentifier("voiceStyle")
                            }
                        }
                        if let info = state.info, info.speakers.count > 1 {
                            Picker("話者", selection: $state.selectedSpeaker) {
                                ForEach(info.speakers.keys.sorted(), id: \.self) { Text($0).tag(info.speakers[$0]!) }
                            }.disabled(state.busy)
                        }
                        Divider()
                        ZStack(alignment: .topLeading) {
                            if state.text.isEmpty {
                                Text("読み上げたい文章を入力してください")
                                    .foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5)
                            }
                            TextEditor(text: $state.text).font(.body).scrollContentBackground(.hidden)
                                .frame(minHeight: 220).focused($editing)
                                .accessibilityLabel("読み上げる文章").accessibilityIdentifier("speechText")
                        }
                        HStack {
                            Text("端末内で音声を生成します").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(state.text.count)文字").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.primary.opacity(0.07), lineWidth: 1))

                    HStack(alignment: .top, spacing: 9) {
                        if state.busy && state.phase != .playing { ProgressView().controlSize(.small) }
                        else { Image(systemName: statusSymbol).foregroundStyle(state.phase == .failed ? Color.orange : DemoStyle.accent) }
                        Text(state.status).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("speechStatus")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if state.phase == .playing { ProgressView(value: state.playbackProgress).tint(DemoStyle.accent) }
                    if let metrics = state.metrics {
                        HStack(spacing: 0) {
                            metric("生成時間", String(format: "%.2f秒", metrics.synthesisSeconds))
                            metric("音声の長さ", String(format: "%.1f秒", metrics.audioSeconds))
                            metric("RTF", String(format: "%.3f", metrics.rtf))
                        }.padding(.vertical, 14).background(DemoStyle.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(maxWidth: 640).padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 12) {
                Button {
                    editing = false
                    if state.assets.count != 3 { showingModels = true }
                    else if !state.ready { state.prepare() }
                    else { state.speak() }
                } label: {
                    Label(actionTitle, systemImage: state.ready ? "waveform" : "sparkle")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                }.buttonStyle(.borderedProminent).tint(DemoStyle.accent).controlSize(.large).accessibilityIdentifier("generateSpeech")
                    .disabled(state.busy || (state.ready && state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if state.busy {
                    Button(action: state.stop) { Image(systemName: "stop.fill").frame(width: 24, height: 30) }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityLabel("停止").accessibilityIdentifier("stopSpeech")
                } else if state.canReplay {
                    Button(action: state.replay) { Image(systemName: "arrow.counterclockwise").frame(width: 24, height: 30) }
                        .buttonStyle(.bordered).controlSize(.large).accessibilityLabel("もう一度再生").accessibilityIdentifier("replaySpeech").help("もう一度再生")
                }
            }.frame(maxWidth: 640).padding(.horizontal, 24).padding(.vertical, 18).frame(maxWidth: .infinity)
                .background(.bar)
        }
        .background(DemoStyle.background)
        .tint(DemoStyle.accent)
        .sheet(isPresented: $showingModels) { ModelSettings(state: state) }
        #if os(macOS)
        .frame(minWidth: 500, idealWidth: 580, minHeight: 600, idealHeight: 680)
        #else
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("完了") { editing = false } }
        }
        #endif
    }
    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }
}

struct ModelSettings: View {
    @ObservedObject var state: DemoState
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var selectedAsset: DemoState.Asset = .bert
    var body: some View {
        NavigationStack {
            Form {
                Section("使用するモデル") {
                    folder("共通モデル", kind: .bert, symbol: "square.stack.3d.up")
                    folder("声モデル", kind: .voice, symbol: "person.wave.2")
                    DisclosureGroup("辞書を個別に指定") { folder("日本語辞書", kind: .dictionary, symbol: "book.closed") }
                }
                Section {
                    Button("準備・ウォームアップ", action: state.prepare).accessibilityIdentifier("prepareModels").disabled(state.busy || state.assets.count != 3)
                    Text(state.status).font(.caption).foregroundStyle(.secondary)
                } footer: {
                    Text("共通フォルダを選ぶとBERTと辞書を自動で読み取ります。初回の準備には時間がかかります。")
                }
                Section {
                    DisclosureGroup("URLからモデルを取得") {
                        Picker("取得するモデル", selection: Binding(get: { state.downloadKind }, set: state.chooseDownloadKind)) {
                            Text("共通モデル").tag(DemoState.Asset.bert)
                            Text("声モデル").tag(DemoState.Asset.voice)
                        }.disabled(state.busy)
                        if state.downloadKind == .bert {
                            Picker("共通モデルの版", selection: Binding(get: { state.commonDownload }, set: state.chooseCommonDownload)) {
                                ForEach(DemoState.CommonDownload.allCases) { preset in Text(preset.rawValue).tag(preset) }
                            }.accessibilityIdentifier("commonDownloadVariant").disabled(state.busy)
                            Text("INT8は容量を抑えられます。FP32は量子化前の重みです。INT8は最初の準備に時間がかかる場合があります。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        TextField("download.json のHTTPS URL", text: Binding(get: { state.downloadURL }, set: state.editDownloadURL))
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("modelManifestURL").disabled(state.busy)
                        Button("ダウンロード", action: state.download).accessibilityIdentifier("downloadModel")
                            .disabled(state.busy || state.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                Section {
                    Text("サンプル・SDK：AGPL-3.0").font(.caption)
                    Text("音声モデル・BERT・辞書には、それぞれのライセンスが適用されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).navigationTitle("モデル設定")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() }.accessibilityIdentifier("closeModelSettings") } }
        }
        .tint(DemoStyle.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
            do { state.select(try result.get(), kind: selectedAsset) }
            catch { state.status = error.localizedDescription }
        }
        #if os(macOS)
        .frame(width: 500, height: 540)
        #endif
    }
    private func folder(_ title: String, kind: DemoState.Asset, symbol: String) -> some View {
        Button { selectedAsset = kind; importing = true } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24).foregroundStyle(DemoStyle.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).foregroundStyle(.primary)
                    Text(kind == .bert ? state.commonModelLabel : state.assets[kind]?.lastPathComponent ?? "未選択")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "folder").foregroundStyle(.secondary)
            }.padding(.vertical, 5).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("choose-\(kind.rawValue.lowercased())").disabled(state.busy)
    }
}
