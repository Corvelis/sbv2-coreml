import Foundation
import SBV2Native
import Darwin

final class StyleBertVits2EngineIOS {
    private var sessionHandle: UnsafeMutableRawPointer?
    private var isInitialized = false
    private var cachedTokenizer: BertTokenizer?
    private var cachedTokenizerPath: String?
    private var coreMLVoice: StyleBertVits2CoreMLVoice?
    private var lastUsedCoreMLVoice = false
    private var lastFastDecoderUsed = false
    private var lastFastDecoderFrames = 0.0
    private var lastDecoderTailMs = 0.0
    private var lastFastTailUsed = false
    private var style2idMap: [String: Int] = [:]
    private var lastError: String = ""

    private(set) var lastBertDurationMs: Double = 0
    private(set) var lastTtsDurationMs: Double = 0
    private(set) var lastTotalDurationMs: Double = 0
    private(set) var lastNativeTotalDurationMs: Double = 0
    private(set) var lastG2PDurationMs: Double = 0
    private(set) var lastTokenizerDurationMs: Double = 0
    private(set) var lastBertExpandDurationMs: Double = 0
    private(set) var lastStyleVectorDurationMs: Double = 0
    private(set) var lastTokenCount: Int = 0
    private(set) var lastPhonemeCount: Int = 0
    private(set) var lastAudioSampleCount: Int = 0
    private(set) var lastHybridPreDurationMs: Double = 0
    private(set) var lastHybridIslandDurationMs: Double = 0
    private(set) var lastHybridFlowDurationMs: Double = 0
    private(set) var lastHybridFlowStage0DurationMs: Double = 0
    private(set) var lastHybridFlowStage1DurationMs: Double = 0
    private(set) var lastHybridFlowStage2DurationMs: Double = 0
    private(set) var lastHybridFlowStage3DurationMs: Double = 0
    private(set) var lastHybridFlowStage4DurationMs: Double = 0
    private(set) var lastHybridFlowStage5DurationMs: Double = 0
    private(set) var lastHybridDecoderDurationMs: Double = 0
    private(set) var lastHybridDecoderStageDurationsMs: [Double] = Array(repeating: 0, count: 6)
    private(set) var lastHybridDecoderSubstageDurationsMs: [[Double]] = Array(
        repeating: Array(repeating: 0, count: 5),
        count: 6,
    )
    private(set) var lastHybridDecoderSubstageShapes: [[String]] = Array(
        repeating: Array(repeating: "", count: 5),
        count: 6,
    )
    private(set) var lastHybridDecoderSubstageErrors: [[String]] = Array(
        repeating: Array(repeating: "", count: 5),
        count: 6,
    )
    private(set) var lastHybridBackDecoderError: String = ""
    private(set) var lastHybridPairedDecoderError: String = ""
    private(set) var lastHybridCombinedDecoderError: String = ""
    private(set) var lastHybridFlowStage5Error: String = ""
    private(set) var lastHybridPostDurationMs: Double = 0

    private let sampleRate = 44100

    private func dataFromInt64Array(_ values: [Int64]) -> Data {
        guard !values.isEmpty else { return Data() }
        return values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    private func dataFromInt32Array(_ values: [Int32]) -> Data {
        guard !values.isEmpty else { return Data() }
        return values.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    func initialize(
        bertModelPath: String,
        ttsModelPath: String,
        configPath: String,
        styleVecPath: String
    ) -> Bool {
        if isInitialized {
            return true
        }
        lastError = ""
        for path in [ttsModelPath, configPath, styleVecPath] {
            guard FileManager.default.fileExists(atPath: path) else {
                lastError = "Model file not found: \(path)"
                return false
            }
        }

        guard #available(iOS 18.0, macOS 15.0, *) else {
            lastError = "Core ML voice models require iOS 18 or macOS 15"
            return false
        }
        guard let voice = StyleBertVits2CoreMLVoice(voiceModelPath: ttsModelPath) else {
            lastError = "Core ML voice bundle is missing or invalid. Use sbv2-coreml convert and select the complete output folder."
            return false
        }
        guard let handle = StyleBertVits2CoreMLBert.createSession(withBertPath: bertModelPath) else {
            lastError = StyleBertVits2CoreMLBert.lastError()
            return false
        }
        do {
            try voice.prepareFlowModels()
        } catch {
            StyleBertVits2CoreMLBert.releaseSession(handle)
            lastError = "Failed to load Core ML voice models: \(error)"
            return false
        }
        sessionHandle = handle
        coreMLVoice = voice
        NSLog("[SBV2CoreML] Initialized native Core ML BERT and voice")

        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataJson = json["data"] as? [String: Any],
           let style2id = dataJson["style2id"] as? [String: Int] {
            style2idMap = style2id
        } else {
            style2idMap = ["Neutral": 0]
        }

        isInitialized = true
        return true
    }

    func synthesize(
        text: String,
        speakerId: Int,
        style: String,
        speed: Float,
        vocabPath: String,
        styleVecPath: String
    ) -> Data? {
        let nativeTotalStart = Date()
        lastError = ""
        lastNativeTotalDurationMs = 0
        lastG2PDurationMs = 0
        lastTokenizerDurationMs = 0
        lastBertExpandDurationMs = 0
        lastStyleVectorDurationMs = 0
        lastTokenCount = 0
        lastPhonemeCount = 0
        lastAudioSampleCount = 0
        NSLog("[SBV2CoreML] synthesize:start textLen=%d speakerId=%d style=%@ speed=%.3f",
              text.count,
              speakerId,
              style,
              speed)
        guard isInitialized, let sessionHandle = sessionHandle, let coreMLVoice else {
            lastError = "Engine not initialized"
            NSLog("[SBV2CoreML] synthesize:abort engine not initialized")
            return nil
        }

        let g2pStart = Date()
        NSLog("[SBV2CoreML] synthesize:before_g2p")
        guard let g2p = JapaneseG2POpenJTalk.convertTextToPhonemes(text: text, tokenCount: 0) else {
            lastError = "G2P failed"
            NSLog("[SBV2CoreML] synthesize:g2p_failed")
            return nil
        }
        lastG2PDurationMs = Date().timeIntervalSince(g2pStart) * 1000.0
        NSLog("[SBV2CoreML] synthesize:after_g2p")
        NSLog("[SBV2CoreML] G2P phonemes=%d tones=%d word2ph=%d", g2p.phonemes.count, g2p.tones.count, g2p.word2ph.count)

        let tokenizerStart = Date()
        let tokenizer: BertTokenizer
        if let cachedTokenizer = cachedTokenizer, cachedTokenizerPath == vocabPath {
            tokenizer = cachedTokenizer
        } else {
            do {
                NSLog("[SBV2CoreML] synthesize:before_tokenizer_init")
                tokenizer = try BertTokenizer(vocabPath: vocabPath)
                self.cachedTokenizer = tokenizer
                self.cachedTokenizerPath = vocabPath
                NSLog("[SBV2CoreML] synthesize:after_tokenizer_init")
            } catch {
                lastError = "Failed to load vocab: \(error)"
                NSLog("[SBV2CoreML] synthesize:tokenizer_init_failed %@", String(describing: error))
                return nil
            }
        }
        let tokenizerOutput: BertTokenizer.TokenizerOutput
        do {
            NSLog("[SBV2CoreML] synthesize:before_tokenize")
            tokenizerOutput = try tokenizer.tokenize(g2p.originalText)
            NSLog("[SBV2CoreML] synthesize:after_tokenize")
        } catch {
            lastError = "Tokenize failed: \(error)"
            NSLog("[SBV2CoreML] synthesize:tokenize_failed %@", String(describing: error))
            return nil
        }
        lastTokenizerDurationMs = Date().timeIntervalSince(tokenizerStart) * 1000.0
        lastTokenCount = tokenizerOutput.tokenIds.count
        NSLog("[SBV2CoreML] Token count=%d", tokenizerOutput.tokenIds.count)

        let g2pWithBlank = applyAddBlank(g2p)
        guard g2pWithBlank.phonemeIds.count <= 128 else {
            lastError = "phoneme count \(g2pWithBlank.phonemeIds.count) exceeds 128"
            return nil
        }
        let word2phSum = g2pWithBlank.word2ph.reduce(0, +)
        NSLog("[SBV2CoreML] After add_blank phonemes=%d word2phSum=%d", g2pWithBlank.phonemeIds.count, word2phSum)

        let bertStart = Date()
        NSLog("[SBV2CoreML] synthesize:before_bert tokenCount=%d", tokenizerOutput.tokenIds.count)
        let tokenIdsData = dataFromInt64Array(tokenizerOutput.tokenIds)
        let attentionMaskData = dataFromInt64Array(tokenizerOutput.attentionMask)
        let bertFeaturesData = StyleBertVits2CoreMLBert.runBertInferenceData(
            withSession: sessionHandle,
            tokenIdsData: tokenIdsData,
            attentionMaskData: attentionMaskData
        )
        NSLog("[SBV2CoreML] synthesize:after_bert bytes=%d", bertFeaturesData.count)
        let bertEnd = Date()
        let bertDuration = bertEnd.timeIntervalSince(bertStart) * 1000.0

        if bertFeaturesData.isEmpty || bertFeaturesData.count % MemoryLayout<Float>.stride != 0 {
            let bertError = StyleBertVits2CoreMLBert.lastError()
            lastError = bertError.isEmpty || bertError == "(empty)"
                ? "BERT inference returned empty output"
                : "BERT inference returned empty output: \(bertError)"
            return nil
        }
        NSLog("[SBV2CoreML] BERT features count=%d", bertFeaturesData.count / MemoryLayout<Float>.stride)

        let bertExpandStart = Date()
        let featureDim = 1024
        let word2phData = dataFromInt32Array(g2pWithBlank.word2ph.map { Int32($0) })
        NSLog("[SBV2CoreML] synthesize:before_expand_bert word2phCount=%d", g2pWithBlank.word2ph.count)
        let jaBertData = StyleBertVits2CoreMLBert.expandBertFeaturesData(
            bertFeaturesData,
            word2phData: word2phData,
            tokenLen: tokenizerOutput.tokenIds.count,
            featureDim: featureDim
        )
        NSLog("[SBV2CoreML] synthesize:after_expand_bert bytes=%d", jaBertData.count)
        lastBertExpandDurationMs = Date().timeIntervalSince(bertExpandStart) * 1000.0

        if jaBertData.isEmpty || jaBertData.count % MemoryLayout<Float>.stride != 0 {
            lastError = "BERT expansion returned empty output"
            return nil
        }
        NSLog("[SBV2CoreML] jaBert count=%d", jaBertData.count / MemoryLayout<Float>.stride)

        let phonemeIds = g2pWithBlank.phonemeIds
        lastPhonemeCount = phonemeIds.count
        let tones = g2pWithBlank.tones
        let langIds = Array(repeating: Int64(1), count: phonemeIds.count)

        let styleVectorStart = Date()
        let styleIndex = style2idMap[style] ?? 0
        guard let styleVec = StyleVectorLoader.loadStyleVector(filePath: styleVecPath, styleIndex: styleIndex) else {
            lastError = "Failed to load style vector (index \(styleIndex))"
            NSLog("[SBV2CoreML] synthesize:stylevec_failed index=%d", styleIndex)
            return nil
        }
        lastStyleVectorDurationMs = Date().timeIntervalSince(styleVectorStart) * 1000.0
        NSLog("[SBV2CoreML] styleVec count=%d", styleVec.count)

        let sdpRatio: Float = 0.2
        let noiseScale: Float = 0.6
        let noiseScaleW: Float = 0.8

        let ttsStart = Date()
        NSLog("[SBV2CoreML] synthesize:before_tts phonemeCount=%d", phonemeIds.count)
        let audioData: Data
        let coreMLMetrics: StyleBertVits2CoreMLVoice.Metrics
        do {
            let decoderChunkFrames = Int(
                ProcessInfo.processInfo.environment["SBV2_DECODER_CHUNK_FRAMES"] ?? ""
            ) ?? 512
            (audioData, coreMLMetrics) = try coreMLVoice.synthesize(
                phonemes: phonemeIds,
                tones: tones,
                languages: langIds,
                jaBertData: jaBertData,
                styleVector: styleVec,
                speakerId: speakerId,
                speed: speed,
                noiseScale: noiseScale,
                noiseScaleW: noiseScaleW,
                sdpRatio: sdpRatio,
                decoderChunkFrames: decoderChunkFrames
            )
        } catch {
            lastError = "Core ML voice failed: \(error)"
            NSLog("[SBV2CoreML] %@", lastError)
            return nil
        }
        lastUsedCoreMLVoice = true
        lastFastDecoderUsed = coreMLMetrics.fastDecoderUsed
        lastFastDecoderFrames = coreMLMetrics.fastDecoderFrames
        lastDecoderTailMs = coreMLMetrics.decoderTailMs
        lastFastTailUsed = coreMLMetrics.fastTailUsed
        lastBertDurationMs = bertDuration
        lastTtsDurationMs = Date().timeIntervalSince(ttsStart) * 1000.0
        lastTotalDurationMs = lastBertDurationMs + lastTtsDurationMs
        // Keep these public metric keys compatible with existing profiling reports.
        lastHybridPreDurationMs = coreMLMetrics.preMs
        lastHybridIslandDurationMs = coreMLMetrics.sdpMs
        lastHybridFlowDurationMs = coreMLMetrics.flowMs
        lastHybridDecoderDurationMs = coreMLMetrics.decoderMs

        if audioData.isEmpty || audioData.count % MemoryLayout<Float>.stride != 0 {
            lastError = "Core ML voice returned empty or invalid audio"
            return nil
        }

        lastAudioSampleCount = audioData.count / MemoryLayout<Float>.stride
        lastNativeTotalDurationMs = Date().timeIntervalSince(nativeTotalStart) * 1000.0

        NSLog("[SBV2CoreML] synthesize:done samples=%d", lastAudioSampleCount)
        return audioData
    }

    func getLastError() -> String {
        return lastError
    }

    func getPerformanceMetrics() -> [String: Any] {
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let memoryStatus = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var metrics: [String: Any] = [
            "thermalState": Double(ProcessInfo.processInfo.thermalState.rawValue),
            "bertMs": lastBertDurationMs,
            "ttsMs": lastTtsDurationMs,
            "totalMs": lastTotalDurationMs,
            "nativeTotalMs": lastNativeTotalDurationMs,
            "g2pMs": lastG2PDurationMs,
            "tokenizerMs": lastTokenizerDurationMs,
            "bertExpandMs": lastBertExpandDurationMs,
            "styleVectorMs": lastStyleVectorDurationMs,
            "tokenCount": lastTokenCount,
            "phonemeCount": lastPhonemeCount,
            "outputSampleCount": lastAudioSampleCount,
            "hybridPreMs": lastHybridPreDurationMs,
            "hybridIslandMs": lastHybridIslandDurationMs,
            "hybridFlowMs": lastHybridFlowDurationMs,
            "hybridFlowStage0Ms": lastHybridFlowStage0DurationMs,
            "hybridFlowStage1Ms": lastHybridFlowStage1DurationMs,
            "hybridFlowStage2Ms": lastHybridFlowStage2DurationMs,
            "hybridFlowStage3Ms": lastHybridFlowStage3DurationMs,
            "hybridFlowStage4Ms": lastHybridFlowStage4DurationMs,
            "hybridFlowStage5Ms": lastHybridFlowStage5DurationMs,
            "hybridDecoderMs": lastHybridDecoderDurationMs,
            "hybridFlowStage5Error": lastHybridFlowStage5Error,
            "hybridBackDecoderError": lastHybridBackDecoderError,
            "hybridPairedDecoderError": lastHybridPairedDecoderError,
            "hybridCombinedDecoderError": lastHybridCombinedDecoderError,
            "hybridDecoderStage0Ms": lastHybridDecoderStageDurationsMs[0],
            "hybridDecoderStage1Ms": lastHybridDecoderStageDurationsMs[1],
            "hybridDecoderStage2Ms": lastHybridDecoderStageDurationsMs[2],
            "hybridDecoderStage3Ms": lastHybridDecoderStageDurationsMs[3],
            "hybridDecoderStage4Ms": lastHybridDecoderStageDurationsMs[4],
            "hybridDecoderStage5Ms": lastHybridDecoderStageDurationsMs[5],
            "hybridPostMs": lastHybridPostDurationMs
        ]
        if memoryStatus == KERN_SUCCESS {
            metrics["processPhysicalFootprintBytes"] = Double(memory.phys_footprint)
            metrics["processResidentBytes"] = Double(memory.resident_size)
        }
        metrics["coreMLVoiceUsed"] = lastUsedCoreMLVoice ? 1.0 : 0.0
        metrics["fastDecoderUsed"] = lastFastDecoderUsed ? 1.0 : 0.0
        metrics["fastDecoderFrames"] = lastFastDecoderFrames
        metrics["decoderTailMs"] = lastDecoderTailMs
        metrics["fastTailUsed"] = lastFastTailUsed ? 1.0 : 0.0
        for stage in 0..<6 {
            for sub in 0..<5 {
                metrics["hybridDecoderStage\(stage)Sub\(sub)Ms"] = lastHybridDecoderSubstageDurationsMs[stage][sub]
                metrics["hybridDecoderStage\(stage)Sub\(sub)Shape"] = lastHybridDecoderSubstageShapes[stage][sub]
                metrics["hybridDecoderStage\(stage)Sub\(sub)Error"] = lastHybridDecoderSubstageErrors[stage][sub]
            }
        }
        return metrics
    }

    func getSampleRate() -> Int {
        return sampleRate
    }

    func release() {
        if let handle = sessionHandle {
            StyleBertVits2CoreMLBert.releaseSession(handle)
        }
        sessionHandle = nil
        isInitialized = false
        cachedTokenizer = nil
        cachedTokenizerPath = nil
        coreMLVoice = nil
        lastUsedCoreMLVoice = false
        lastFastDecoderUsed = false
        lastFastDecoderFrames = 0
        lastDecoderTailMs = 0
        lastFastTailUsed = false
    }

    private func applyAddBlank(_ g2p: JapaneseG2POpenJTalk.G2PResult) -> JapaneseG2POpenJTalk.G2PResult {
        func intersperse<T>(_ list: [T], _ separator: T) -> [T] {
            if list.isEmpty { return list }
            var result: [T] = [separator]
            for item in list {
                result.append(item)
                result.append(separator)
            }
            return result
        }

        let newPhonemes = intersperse(g2p.phonemes, "_")
        let newPhonemeIds = intersperse(g2p.phonemeIds, 0)
        let newTones = intersperse(g2p.tones, 0)

        var newWord2ph = g2p.word2ph.map { $0 * 2 }
        if !newWord2ph.isEmpty {
            newWord2ph[0] += 1
        }

        return JapaneseG2POpenJTalk.G2PResult(
            phonemes: newPhonemes,
            phonemeIds: newPhonemeIds,
            tones: newTones,
            word2ph: newWord2ph,
            katakana: g2p.katakana,
            originalText: g2p.originalText
        )
    }
}
