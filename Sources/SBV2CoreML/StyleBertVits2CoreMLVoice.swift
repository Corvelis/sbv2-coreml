import CoreML
import Foundation
import SBV2Native
import Darwin

/// Voice-specific Core ML inference. Text cleanup and BERT remain in the engine.
final class StyleBertVits2CoreMLVoice {
    enum VoiceError: Error {
        case invalidInput(String)
        case missingModel(String)
        case invalidOutput(String)
    }

    struct Metrics {
        var preMs = 0.0
        var sdpMs = 0.0
        var flowMs = 0.0
        var decoderMs = 0.0
        var fastDecoderUsed = false
        var fastDecoderFrames = 0.0
        var decoderTailMs = 0.0
        var fastTailUsed = false
    }

    private let voiceDirectory: URL
    private let blocksDirectory: URL
    private let fastDecoderAvailable: Bool
    private let fastDecoder384Available: Bool
    private let fastTail32Available: Bool
    private let sharedPackage: URL?
    private let sharedFunctions: Set<String>
    private var compiledPackages: [URL: URL] = [:]
    private var loadedModels: [String: MLModel] = [:]
    private var gaussianSpare: Float?
    // Only a developer-launched validation process supplies this variable.
    // Regular launches keep the original system random generator.
    private var validationRandomState = ProcessInfo.processInfo.environment["SBV2_TEST_SEED"].flatMap(UInt64.init)

    init?(voiceModelPath: String) {
        let root = URL(fileURLWithPath: voiceModelPath).deletingLastPathComponent()
        let blocks = root.appendingPathComponent("coreml_voice", isDirectory: true)
        let manifest = blocks.appendingPathComponent("coreml_voice_blocks_manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let merged: URL?
        let functions: Set<String>
        if let shared = json["multifunction"] as? [String: Any] {
            guard #available(iOS 18.0, *),
                  shared["mlpackage"] as? String == "voice_shared.mlpackage",
                  let names = shared["functions"] as? [String] else { return nil }
            merged = blocks.appendingPathComponent("voice_shared.mlpackage", isDirectory: true)
            functions = Set(names)
            guard FileManager.default.fileExists(atPath: merged!.appendingPathComponent("Manifest.json").path) else { return nil }
        } else {
            guard json["multifunction"] == nil else { return nil }
            merged = nil
            functions = []
        }
        func hasModel(_ name: String, in directory: URL) -> Bool {
            if merged != nil { return functions.contains(name) }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(name).mlpackage/Manifest.json").path)
        }
        for name in ["pre_64", "pre_128", "sdp_64", "sdp_128", "flow_64", "flow_128", "flow_256", "flow_512"] {
            guard hasModel(name, in: blocks) else { return nil }
        }
        let hybrid = root.appendingPathComponent("hybrid", isDirectory: true)
        guard hasModel("decoder_combined_flex", in: hybrid) else { return nil }
        voiceDirectory = root
        blocksDirectory = blocks
        sharedPackage = merged
        sharedFunctions = functions
        fastDecoderAvailable = hasModel("decoder_combined_len_256_fp16", in: hybrid) &&
            ProcessInfo.processInfo.environment["SBV2_DECODER_FP32"] != "1"
        fastDecoder384Available = fastDecoderAvailable &&
            ProcessInfo.processInfo.environment["SBV2_DECODER_384_TRIAL"] == "1" &&
            hasModel("decoder_combined_len_384_fp16", in: hybrid)
        fastTail32Available = fastDecoderAvailable &&
            ProcessInfo.processInfo.environment["SBV2_DECODER_TAIL_FP32"] != "1" &&
            hasModel("decoder_combined_len_32_fp16", in: hybrid)
    }

    /// Load every fixed size before the first turn. Text and SDP length 128
    /// can first appear several turns later and otherwise add a cold load in
    /// the middle of an LLM response.
    func prepareFlowModels() throws {
        let started = ProcessInfo.processInfo.systemUptime
        for name in [
            "pre_64", "pre_128", "sdp_64", "sdp_128",
            "flow_64", "flow_128", "flow_256", "flow_512", "decoder",
        ] {
            // Compiling/loading one model can leave large Objective-C
            // temporaries. Drain them before loading the next fixed shape.
            try autoreleasepool { _ = try model(named: name) }
            logValidationMemory(name)
        }
        if fastDecoder384Available { try autoreleasepool { _ = try model(named: "decoder_384") } }
        if fastDecoderAvailable { try autoreleasepool { _ = try model(named: "decoder_tail_fp32") } }
        if fastTail32Available { try autoreleasepool { _ = try model(named: "decoder_tail_32") } }
        logValidationMemory("prepared")
        NSLog("[SBV2CoreML] Core ML voice prepared in %.1f ms", (ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    private func logValidationMemory(_ stage: String) {
        guard validationRandomState != nil else { return }
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &memory) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            NSLog("[EdgeTTS] validation memory %@: %.1f MiB", stage, Double(memory.phys_footprint) / 1048576)
        }
    }

    private func latestModificationDate(at root: URL) -> Date? {
        let manager = FileManager.default
        var latest = (try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return latest
        }
        for case let item as URL in enumerator {
            if let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               latest == nil || modified > latest! {
                latest = modified
            }
        }
        return latest
    }

    /// Keep the compiled model at a fixed path so Core ML can reuse its device
    /// specialization on later launches. Imported voice bundles are writable;
    /// read-only bundles still work through the temporary compiled result.
    private func compiledModel(at package: URL) throws -> URL {
        let manager = FileManager.default
        let cache = package.deletingPathExtension().appendingPathExtension("mlmodelc")
        if manager.fileExists(atPath: cache.path),
           let sourceDate = latestModificationDate(at: package),
           let cacheDate = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           cacheDate >= sourceDate {
            return cache
        }

        let temporary = try MLModel.compileModel(at: package)
        let staging = cache.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mlmodelc")
        do {
            try manager.copyItem(at: temporary, to: staging)
            if manager.fileExists(atPath: cache.path) {
                try manager.removeItem(at: cache)
            }
            try manager.moveItem(at: staging, to: cache)
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: cache.path)
            try? manager.removeItem(at: temporary)
            return cache
        } catch {
            try? manager.removeItem(at: staging)
            NSLog("[SBV2CoreML] Core ML voice cache unavailable: %@", String(describing: error))
            return temporary
        }
    }

    private func model(named name: String) throws -> MLModel {
        if let loaded = loadedModels[name] { return loaded }
        // A different sentence can select a different fixed Flow length.
        // Unloading the previous length here made a later sentence spend up to
        // ~1 second reloading it, so retain the fixed models for this voice.
        var package: URL
        if name == "decoder_tail_fp32" {
            package = voiceDirectory.appendingPathComponent("hybrid/decoder_combined_flex.mlpackage", isDirectory: true)
        } else if name == "decoder_tail_32" {
            package = voiceDirectory.appendingPathComponent("hybrid/decoder_combined_len_32_fp16.mlpackage", isDirectory: true)
        } else if name == "decoder_384" {
            package = voiceDirectory.appendingPathComponent("hybrid/decoder_combined_len_384_fp16.mlpackage", isDirectory: true)
        } else if name == "decoder" {
            package = voiceDirectory.appendingPathComponent(
                fastDecoderAvailable ? "hybrid/decoder_combined_len_256_fp16.mlpackage" :
                    "hybrid/decoder_combined_flex.mlpackage",
                isDirectory: true
            )
        } else {
            package = blocksDirectory.appendingPathComponent("\(name).mlpackage", isDirectory: true)
        }
        let functionName: String?
        if let sharedPackage {
            let function = package.deletingPathExtension().lastPathComponent
            guard sharedFunctions.contains(function) else { throw VoiceError.missingModel(function) }
            functionName = function
            package = sharedPackage
        } else {
            functionName = nil
        }
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw VoiceError.missingModel(name)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let compiled: URL
        if let cached = compiledPackages[package] {
            compiled = cached
        } else {
            compiled = try compiledModel(at: package)
            compiledPackages[package] = compiled
        }
        let configuration = MLModelConfiguration()
        if #available(iOS 18.0, *), let functionName {
            configuration.functionName = functionName
        }
        // The text encoder, Flow and Decoder GPU MPSGraph paths abort on iOS
        // 27, so keep this voice on CPU and Neural Engine.
        if #available(iOS 16.0, *) {
            let decoderCpuOnly = (name == "decoder" || name == "decoder_384" || name == "decoder_tail_32") &&
                ProcessInfo.processInfo.environment["SBV2_DECODER_CPU_ONLY"] == "1"
            configuration.computeUnits = decoderCpuOnly ? .cpuOnly : .cpuAndNeuralEngine
        } else {
            configuration.computeUnits = .cpuOnly
        }
        let loaded: MLModel
        do {
            loaded = try MLModel(contentsOf: compiled, configuration: configuration)
        } catch {
            let cache = package.deletingPathExtension().appendingPathExtension("mlmodelc")
            guard compiled == cache else { throw error }
            // An interrupted update can leave an unusable cache. Recompile
            // from the original package once before failing initialization.
            try FileManager.default.removeItem(at: cache)
            let replacement = try compiledModel(at: package)
            compiledPackages[package] = replacement
            loaded = try MLModel(contentsOf: replacement, configuration: configuration)
        }
        loadedModels[name] = loaded
        NSLog("[SBV2CoreML] Core ML voice model %@ loaded in %.1f ms", name, (ProcessInfo.processInfo.systemUptime - started) * 1000)
        return loaded
    }

    private func floatTensor(_ values: [Float], shape: [Int]) throws -> MLMultiArray {
        guard shape.reduce(1, *) == values.count else {
            throw VoiceError.invalidInput("float tensor shape")
        }
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: .float32)
        let destination = array.dataPointer.bindMemory(to: Float.self, capacity: values.count)
        values.withUnsafeBufferPointer { buffer in
            destination.update(from: buffer.baseAddress!, count: values.count)
        }
        return array
    }

    private func intTensor(_ values: [Int32], shape: [Int]) throws -> MLMultiArray {
        // The converted PyTorch models expose all inputs as Float32 and cast
        // token IDs to integer tensors inside the graph.
        try floatTensor(values.map { Float($0) }, shape: shape)
    }

    private func values(from array: MLMultiArray) throws -> [Float] {
        let dimensions = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        let count = dimensions.reduce(1, *)
        let physicalCount = 1 + zip(dimensions, strides).reduce(0) { partial, pair in
            partial + (pair.0 - 1) * pair.1
        }
        var expectedStride = 1
        var contiguous = true
        for axis in dimensions.indices.reversed() {
            if strides[axis] != expectedStride { contiguous = false; break }
            expectedStride *= dimensions[axis]
        }
        func offset(for flat: Int) -> Int {
            var remaining = flat
            var offset = 0
            for axis in dimensions.indices.reversed() {
                offset += (remaining % dimensions[axis]) * strides[axis]
                remaining /= dimensions[axis]
            }
            return offset
        }
        switch array.dataType {
        case .float32:
            let source = array.dataPointer.bindMemory(to: Float.self, capacity: physicalCount)
            if contiguous { return Array(UnsafeBufferPointer(start: source, count: count)) }
            return (0..<count).map { source[offset(for: $0)] }
        case .float16:
            let source = array.dataPointer.bindMemory(to: UInt16.self, capacity: physicalCount)
            if contiguous { return (0..<count).map { Self.floatFromHalf(source[$0]) } }
            return (0..<count).map { Self.floatFromHalf(source[offset(for: $0)]) }
        default:
            throw VoiceError.invalidOutput("Core ML output is not floating point")
        }
    }

    /// Exact IEEE binary16 conversion, also available when Xcode builds an Intel slice.
    static func floatFromHalf(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits >> 10) & 31)
        let fraction = UInt32(bits & 1023)
        if exponent == 0 {
            if fraction == 0 { return Float(bitPattern: sign) }
            let value = Float(fraction) * Float(0x1p-24)
            return sign == 0 ? value : -value
        }
        if exponent == 31 { return Float(bitPattern: sign | 0x7f800000 | (fraction << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (fraction << 13))
    }

    private func predict(_ name: String, inputs: [String: MLMultiArray], outputs: [String]) throws -> [String: [Float]] {
        // Core ML's autoreleased intermediate buffers need not survive until
        // the whole utterance finishes. Only copied Swift output arrays escape.
        return try autoreleasepool {
            let provider = try MLDictionaryFeatureProvider(
                dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) }
            )
            let prediction = try model(named: name).prediction(from: provider)
            var result: [String: [Float]] = [:]
            for output in outputs {
                guard let array = prediction.featureValue(for: output)?.multiArrayValue else {
                    throw VoiceError.invalidOutput("\(name): \(output)")
                }
                result[output] = try values(from: array)
            }
            return result
        }
    }

    private func normal() -> Float {
        if let spare = gaussianSpare {
            gaussianSpare = nil
            return spare
        }
        let u1 = max(uniformRandom(), 1e-12)
        let u2 = uniformRandom()
        let radius = sqrt(-2 * log(u1))
        let angle = 2 * Double.pi * u2
        gaussianSpare = Float(radius * sin(angle))
        return Float(radius * cos(angle))
    }

    private func uniformRandom() -> Double {
        guard var state = validationRandomState else { return Double.random(in: 0..<1) }
        state &+= 0x9E3779B97F4A7C15
        validationRandomState = state
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / 9007199254740992.0
    }

    func synthesize(
        phonemes: [Int64],
        tones: [Int64],
        languages: [Int64],
        jaBertData: Data,
        styleVector: [Float],
        speakerId: Int,
        speed: Float,
        noiseScale: Float,
        noiseScaleW: Float,
        sdpRatio: Float,
        decoderChunkFrames: Int = 512,
        textLengthOverride: Int? = nil,
        sdpNoiseOverride: [Float]? = nil,
        latentNoiseOverride: [Float]? = nil
    ) throws -> (Data, Metrics) {
        let textCount = phonemes.count
        if textCount > 128 {
            throw VoiceError.invalidInput("phoneme count \(textCount) exceeds 128")
        }
        guard textCount >= 2, textCount <= 128,
              tones.count == textCount, languages.count == textCount,
              jaBertData.count == textCount * 1024 * MemoryLayout<Float>.stride,
              styleVector.count == 256, speed > 0,
              [32, 64, 128, 512].contains(decoderChunkFrames) else {
            throw VoiceError.invalidInput("voice input shape or length")
        }
        let textLength = textLengthOverride ?? (textCount <= 64 ? 64 : 128)
        guard (textLength == 64 || textLength == 128), textLength >= textCount else {
            throw VoiceError.invalidInput("text model length")
        }
        var metrics = Metrics()
        metrics.fastDecoderUsed = fastDecoderAvailable
        var bertRows = [Float](repeating: 0, count: textCount * 1024)
        _ = bertRows.withUnsafeMutableBytes { jaBertData.copyBytes(to: $0) }
        var bertChannels = [Float](repeating: 0, count: 1024 * textLength)
        for phone in 0..<textCount {
            for channel in 0..<1024 {
                bertChannels[channel * textLength + phone] = bertRows[phone * 1024 + channel]
            }
        }
        func paddedIds(_ values: [Int64]) -> [Int32] {
            values.map { Int32(clamping: $0) } + [Int32](repeating: 0, count: textLength - textCount)
        }
        let preStart = Date()
        let pre = try predict("pre_\(textLength)", inputs: [
            "phones": try intTensor(paddedIds(phonemes), shape: [1, textLength]),
            "lengths": try intTensor([Int32(textCount)], shape: [1]),
            "speaker": try intTensor([Int32(speakerId)], shape: [1]),
            "tones": try intTensor(paddedIds(tones), shape: [1, textLength]),
            "languages": try intTensor(paddedIds(languages), shape: [1, textLength]),
            "bert": try floatTensor(bertChannels, shape: [1, 1024, textLength]),
            "style": try floatTensor(styleVector, shape: [1, 256]),
        ], outputs: ["x", "m", "logs", "mask", "g", "logw"])
        metrics.preMs = Date().timeIntervalSince(preStart) * 1000
        guard let x = pre["x"], let m = pre["m"], let logs = pre["logs"],
              let mask = pre["mask"], let g = pre["g"], let normalLogw = pre["logw"] else {
            throw VoiceError.invalidOutput("pre")
        }

        let sdpStart = Date()
        var sdpNoise = [Float](repeating: 0, count: 2 * textLength)
        if let sdpNoiseOverride {
            guard sdpNoiseOverride.count == sdpNoise.count else {
                throw VoiceError.invalidInput("SDP test noise shape")
            }
            sdpNoise = sdpNoiseOverride
        } else {
            for index in sdpNoise.indices { sdpNoise[index] = normal() * noiseScaleW }
        }
        let sdp = try predict("sdp_\(textLength)", inputs: [
            "x": try floatTensor(x, shape: [1, 192, textLength]),
            "mask": try floatTensor(mask, shape: [1, 1, textLength]),
            "g": try floatTensor(g, shape: [1, 512, 1]),
            "noise": try floatTensor(sdpNoise, shape: [1, 2, textLength]),
        ], outputs: ["logw"])
        metrics.sdpMs = Date().timeIntervalSince(sdpStart) * 1000
        guard let stochasticLogw = sdp["logw"] else {
            throw VoiceError.invalidOutput("sdp logw")
        }

        var durations = [Int](repeating: 0, count: textLength)
        var frames = 0
        for phone in 0..<textLength {
            let logw = sdpRatio * stochasticLogw[phone] + (1 - sdpRatio) * normalLogw[phone]
            let value = ceil(Double(exp(logw) * mask[phone] / speed))
            guard value.isFinite, value >= 0, value <= 512 else {
                throw VoiceError.invalidOutput("predicted duration")
            }
            durations[phone] = Int(value)
            frames += durations[phone]
        }
        guard frames >= 16, frames <= 512 else {
            throw VoiceError.invalidOutput("audio frame count \(frames) outside 16...512")
        }
        let flowLength = [64, 128, 256, 512].first { frames <= $0 }!
        if let latentNoiseOverride, latentNoiseOverride.count != 192 * frames {
            throw VoiceError.invalidInput("latent test noise shape")
        }
        var latent = [Float](repeating: 0, count: 192 * flowLength)
        for channel in 0..<192 {
            var frame = 0
            for phone in 0..<textLength {
                let sourceIndex = channel * textLength + phone
                for _ in 0..<durations[phone] {
                    let noise = latentNoiseOverride?[channel * frames + frame] ?? normal()
                    latent[channel * flowLength + frame] =
                        m[sourceIndex] + noise * exp(logs[sourceIndex]) * noiseScale
                    frame += 1
                }
            }
        }
        var flowMask = [Float](repeating: 0, count: flowLength)
        for frame in 0..<frames { flowMask[frame] = 1 }
        let flowStart = Date()
        let flow = try predict("flow_\(flowLength)", inputs: [
            "z": try floatTensor(latent, shape: [1, 192, flowLength]),
            "mask": try floatTensor(flowMask, shape: [1, 1, flowLength]),
            "g": try floatTensor(g, shape: [1, 512, 1]),
        ], outputs: ["output"])
        metrics.flowMs = Date().timeIntervalSince(flowStart) * 1000
        guard let z = flow["output"], z.count == 192 * flowLength else {
            throw VoiceError.invalidOutput("flow output shape")
        }

        let decoderStart = Date()
        var audio = [Float]()
        audio.reserveCapacity(frames * 512)
        let useDecoder384 = fastDecoder384Available && frames > 230
        let fixedDecoderFrames = useDecoder384 ? 384 : 256
        if fastDecoderAvailable { metrics.fastDecoderFrames = Double(fixedDecoderFrames) }
        let decoderName = useDecoder384 ? "decoder_384" : "decoder"
        let chunkFrames = fastDecoderAvailable ? fixedDecoderFrames - 26 : decoderChunkFrames
        for start in stride(from: 0, to: frames, by: chunkFrames) {
            let end = min(start + chunkFrames, frames)
            var left = max(0, start - 13)
            let right = min(frames, end + 13)
            if right - left < 16 { left = max(0, right - 16) }
            let window = fastDecoderAvailable ? fixedDecoderFrames : right - left
            var windowLatent = [Float](repeating: 0, count: 192 * window)
            for channel in 0..<192 {
                for offset in 0..<(right - left) {
                    windowLatent[channel * window + offset] = z[channel * flowLength + left + offset]
                }
            }
            let decoded = try predict(decoderName, inputs: [
                "_Mul_9_output_0": try floatTensor(windowLatent, shape: [1, 192, window]),
                "sid": try intTensor([Int32(speakerId)], shape: [1]),
            ], outputs: ["output"])
            guard let samples = decoded["output"], samples.count == window * 512 else {
                throw VoiceError.invalidOutput("decoder output shape")
            }
            let sampleStart = (start - left) * 512
            audio.append(contentsOf: samples[sampleStart..<(sampleStart + (end - start) * 512)])
        }
        // Padding a fixed decoder input creates nonzero activations beyond the
        // real final frame. Recover the last receptive field using an exact
        // 32-frame window so the final syllable has no padding artifact.
        if fastDecoderAvailable && frames >= 16 {
            let tailStartTime = Date()
            let tailFrames = min(frames, 32)
            let tailStart = frames - tailFrames
            var tailLatent = [Float](repeating: 0, count: 192 * tailFrames)
            for channel in 0..<192 {
                for offset in 0..<tailFrames {
                    tailLatent[channel * tailFrames + offset] = z[channel * flowLength + tailStart + offset]
                }
            }
            let useFastTail32 = fastTail32Available && tailFrames == 32
            let tail = try predict(useFastTail32 ? "decoder_tail_32" : "decoder_tail_fp32", inputs: [
                "_Mul_9_output_0": try floatTensor(tailLatent, shape: [1, 192, tailFrames]),
                "sid": try intTensor([Int32(speakerId)], shape: [1]),
            ], outputs: ["output"])
            guard let tailSamples = tail["output"], tailSamples.count == tailFrames * 512 else {
                throw VoiceError.invalidOutput("decoder tail output shape")
            }
            audio.replaceSubrange((frames - 13) * 512..<frames * 512,
                                  with: tailSamples[(tailFrames - 13) * 512..<tailFrames * 512])
            metrics.decoderTailMs = Date().timeIntervalSince(tailStartTime) * 1000
            metrics.fastTailUsed = useFastTail32
        }
        metrics.decoderMs = Date().timeIntervalSince(decoderStart) * 1000
        let data = audio.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, metrics)
    }

}
