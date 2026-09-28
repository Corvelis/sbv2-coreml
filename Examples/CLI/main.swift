import Foundation
import SBV2CoreML

@main struct Say {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 6 else {
            print("Usage: sbv2-say BERT_DIR VOICE_DIR DICTIONARY_DIR OUTPUT.wav TEXT [STYLE] [SPEAKER_ID]")
            return
        }
        let engine = SpeechSynthesizer()
        let start = ProcessInfo.processInfo.systemUptime
        let info = try await engine.load(ModelPaths(bert: URL(fileURLWithPath: args[1]),
            voice: URL(fileURLWithPath: args[2]), dictionary: URL(fileURLWithPath: args[3])))
        let load = ProcessInfo.processInfo.systemUptime - start
        let style = args.count > 6 ? args[6] : (info.styles["Neutral"] != nil ? "Neutral" : info.styles.min { $0.value < $1.value }!.key)
        let options = SpeechOptions(speakerID: args.count > 7 ? Int(args[7]) ?? -1 : info.speakers.values.min()!, style: style)
        let audio = try await engine.synthesize(args[5], options: options)
        try audio.wav().write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        print(String(format: "load=%.3fs synthesis=%.3fs audio=%.3fs RTF=%.4f", load, audio.synthesisSeconds, audio.duration, audio.rtf))
        try await engine.unload()
    }
}
