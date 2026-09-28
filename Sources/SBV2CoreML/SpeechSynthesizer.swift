import Foundation

public enum SBV2Error: Error, LocalizedError {
    case invalidModel(String), synthesis(String), notLoaded, cancelled
    public var errorDescription: String? {
        switch self {
        case .invalidModel(let s), .synthesis(let s): return s
        case .notLoaded: return "Load a BERT, voice and Open JTalk dictionary first."
        case .cancelled: return "Synthesis cancelled."
        }
    }
}

public struct ModelPaths: Sendable {
    public let bert: URL
    public let voice: URL
    public let dictionary: URL
    public init(bert: URL, voice: URL, dictionary: URL) {
        self.bert = bert; self.voice = voice; self.dictionary = dictionary
    }
}

public struct VoiceInfo: Sendable {
    public let speakers: [String: Int]
    public let styles: [String: Int]
    public let sampleRate: Int
    public init(directory: URL) throws {
        let bytes = try Data(contentsOf: directory.appendingPathComponent("config.json"))
        guard let config = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let data = config["data"] as? [String: Any],
              let speakers = data["spk2id"] as? [String: Int], !speakers.isEmpty,
              let styles = data["style2id"] as? [String: Int], !styles.isEmpty,
              data["sampling_rate"] as? Int == 44100,
              (config["version"] as? String)?.hasSuffix("JP-Extra") == true else {
            throw SBV2Error.invalidModel("Expected a 44.1 kHz JP-Extra voice with speaker/style IDs.")
        }
        self.speakers = speakers; self.styles = styles; sampleRate = 44100
    }
}

public struct SpeechOptions: Sendable {
    public var speakerID: Int
    public var style: String
    public var speed: Float
    public init(speakerID: Int = 0, style: String = "Neutral", speed: Float = 1) {
        self.speakerID = speakerID; self.style = style; self.speed = speed
    }
}

public struct SpeechChunk: Sendable {
    public let text: String
    /// Mono float32 PCM in native byte order (Apple platforms are little endian).
    public let pcm: Data
    public let sampleRate: Int
    public let synthesisSeconds: Double
    public let capacitySplit: Bool
    public var duration: Double { Double(pcm.count / MemoryLayout<Float>.stride) / Double(sampleRate) }
    public var rtf: Double { synthesisSeconds / max(duration, 0.000001) }
    public func wav() throws -> Data {
        var floats = [Float](repeating: 0, count: pcm.count / 4)
        _ = floats.withUnsafeMutableBytes { pcm.copyBytes(to: $0) }
        var audio = Data(capacity: floats.count * 2)
        for value in floats {
            guard value.isFinite else { throw SBV2Error.synthesis("Non-finite PCM sample") }
            var sample = Int16(max(-32768, min(32767, Int((value * 32767).rounded())))).littleEndian
            withUnsafeBytes(of: &sample) { audio.append(contentsOf: $0) }
        }
        var result = Data()
        func tag(_ s: String) { result.append(contentsOf: s.utf8) }
        func number<T: FixedWidthInteger>(_ n: T) {
            var little = n.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        tag("RIFF"); number(UInt32(36 + audio.count)); tag("WAVEfmt ")
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1)); number(UInt32(sampleRate))
        number(UInt32(sampleRate * 2)); number(UInt16(2)); number(UInt16(16))
        tag("data"); number(UInt32(audio.count)); result.append(audio)
        return result
    }
}

/// Dedicated queue keeps Core ML / Open JTalk work off the main thread.
/// All instances serialize native work because the inherited G2P helper has shared state.
public final class SpeechSynthesizer: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "SBV2CoreML.inference", qos: .userInitiated)
    private let native = StyleBertVits2EngineIOS()
    private var paths: ModelPaths?
    private var voice: VoiceInfo?
    private let lock = NSLock()
    private var generation: UInt64 = 0
    public init() {}
    deinit {
        let engine = native
        Self.queue.async { engine.release() }
    }
    private func token() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    public func cancel() { lock.lock(); generation &+= 1; lock.unlock() }
    private func work<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
    @discardableResult public func load(_ paths: ModelPaths) async throws -> VoiceInfo {
        cancel()
        return try await work {
            let info = try VoiceInfo(directory: paths.voice)
            self.native.release(); self.paths = nil; self.voice = nil
            guard JapaneseG2POpenJTalk.initialize(dicPath: paths.dictionary.path) else {
                throw SBV2Error.invalidModel("Open JTalk dictionary could not be loaded.")
            }
            let config = paths.voice.appendingPathComponent("config.json").path
            guard self.native.initialize(bertModelPath: paths.bert.path, ttsModelPath: config,
                    configPath: config, styleVecPath: paths.voice.appendingPathComponent("style_vectors.npy").path) else {
                throw SBV2Error.invalidModel(self.native.getLastError())
            }
            self.paths = paths; self.voice = info
            return info
        }
    }
    public func unload() async throws {
        cancel()
        try await work { self.native.release(); self.paths = nil; self.voice = nil }
    }
    public func warmUp(options: SpeechOptions = .init()) async throws {
        _ = try await synthesize("こんにちは。", options: options)
    }
    /// Pull-based stream: the next segment is synthesized when the caller requests it.
    /// Consumers can await available playback capacity to bound queued PCM memory.
    public func stream(_ text: String, options: SpeechOptions = .init(),
                       segmenter: TextSegmenter = .init()) -> SpeechStream {
        SpeechStream(engine: self, segments: segmenter.split(text), options: options, generation: token())
    }
    public func synthesize(_ text: String, options: SpeechOptions = .init()) async throws -> SpeechChunk {
        var pcm = Data(), seconds = 0.0, split = false
        for try await chunk in stream(text, options: options) {
            pcm.append(chunk.pcm); seconds += chunk.synthesisSeconds; split = split || chunk.capacitySplit
        }
        return SpeechChunk(text: text, pcm: pcm, sampleRate: 44100, synthesisSeconds: seconds, capacitySplit: split)
    }
    fileprivate func segment(_ text: String, options: SpeechOptions, generation: UInt64, split: Bool) async throws -> SpeechChunk {
        try await work {
            guard self.token() == generation else { throw SBV2Error.cancelled }
            guard let paths = self.paths, let info = self.voice else { throw SBV2Error.notLoaded }
            guard info.speakers.values.contains(options.speakerID), info.styles[options.style] != nil,
                  options.speed.isFinite, options.speed > 0 else {
                throw SBV2Error.synthesis("Invalid speaker, style or speed. Read VoiceInfo for valid IDs.")
            }
            // Another instance may have used a different dictionary on the shared serial queue.
            guard JapaneseG2POpenJTalk.initialize(dicPath: paths.dictionary.path) else {
                throw SBV2Error.invalidModel("Open JTalk dictionary could not be loaded.")
            }
            let started = ProcessInfo.processInfo.systemUptime
            let audio: Data? = autoreleasepool {
                self.native.synthesize(text: text, speakerId: options.speakerID, style: options.style,
                    speed: options.speed, vocabPath: paths.bert.appendingPathComponent("vocab.txt").path,
                    styleVecPath: paths.voice.appendingPathComponent("style_vectors.npy").path)
            }
            guard self.token() == generation else { throw SBV2Error.cancelled }
            guard let audio, !audio.isEmpty else { throw SBV2Error.synthesis(self.native.getLastError()) }
            return SpeechChunk(text: text, pcm: audio, sampleRate: 44100,
                synthesisSeconds: ProcessInfo.processInfo.systemUptime - started, capacitySplit: split)
        }
    }
}

public struct SpeechStream: AsyncSequence, Sendable {
    public typealias Element = SpeechChunk
    fileprivate let engine: SpeechSynthesizer
    fileprivate let segments: [String]
    fileprivate let options: SpeechOptions
    fileprivate let generation: UInt64
    public func makeAsyncIterator() -> Iterator {
        Iterator(engine: engine, pending: segments.map { ($0, false) }, options: options, generation: generation)
    }
    public struct Iterator: AsyncIteratorProtocol {
        fileprivate let engine: SpeechSynthesizer
        fileprivate var pending: [(String, Bool)]
        fileprivate let options: SpeechOptions
        fileprivate let generation: UInt64
        public mutating func next() async throws -> SpeechChunk? {
            try Task.checkCancellation()
            guard !pending.isEmpty else { return nil }
            let (text, split) = pending.removeFirst()
            do {
                let result = try await engine.segment(text, options: options, generation: generation, split: split)
                try Task.checkCancellation()
                return result
            } catch SBV2Error.synthesis(let message) {
                let capacity = message.contains("exceeds 128") || message.contains("outside 16...512") ||
                    message.contains("sequence length") || message.contains("token length")
                guard capacity, let halves = TextSegmenter.bisect(text), halves.count == 2 else {
                    throw SBV2Error.synthesis(message)
                }
                pending.insert(contentsOf: halves.map { ($0, true) }, at: 0)
                return try await next()
            }
        }
    }
}
