import XCTest
@testable import SBV2CoreML

final class SegmentationTests: XCTestCase {
    func testHalfConversion() {
        XCTAssertEqual(StyleBertVits2CoreMLVoice.floatFromHalf(0x3c00), 1)
        XCTAssertEqual(StyleBertVits2CoreMLVoice.floatFromHalf(0xbc00), -1)
        XCTAssertEqual(StyleBertVits2CoreMLVoice.floatFromHalf(1), Float(0x1p-24))
        XCTAssertEqual(StyleBertVits2CoreMLVoice.floatFromHalf(0x8000).bitPattern, 0x80000000)
        XCTAssertEqual(StyleBertVits2CoreMLVoice.floatFromHalf(0x7c00), .infinity)
        XCTAssertTrue(StyleBertVits2CoreMLVoice.floatFromHalf(0x7e01).isNaN)
    }
    func testDownloadPathTraversalRejected() throws {
        let json = """
        {"formatVersion":1,"name":"test","files":[{"path":"../escape","sha256":"\(String(repeating: "0", count: 64))","bytes":1}]}
        """
        let manifest = try JSONDecoder().decode(DownloadManifest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try ModelDownloader.validate(manifest))
    }
    func testFirstCommaOnly() {
        XCTAssertEqual(TextSegmenter().split("まず、こんにちは。その後、散歩します。"), ["まず、", "こんにちは。", "その後、散歩します。"])
    }
    func testSentenceNewlineAndClosingQuote() {
        XCTAssertEqual(TextSegmenter().split("「こんにちは。」\n次です。"), ["「こんにちは。」", "次です。"])
    }
    func testForced250WithoutDroppingCharacters() {
        let text = String(repeating: "あ", count: 501)
        let pieces = TextSegmenter().split(text)
        XCTAssertEqual(pieces.map(\.count), [250, 250, 1])
        XCTAssertEqual(pieces.joined(), text)
    }
    func testCapacitySplitPreservesText() {
        let text = "とても長い前半、そして後半が続きます。"
        let split = TextSegmenter.bisect(text)!
        XCTAssertEqual(split.count, 2)
        XCTAssertEqual(split.joined(), text)
    }
    func testWavClamping() throws {
        let values: [Float] = [-2, 0, 2]
        let chunk = SpeechChunk(text: "", pcm: values.withUnsafeBufferPointer { Data(buffer: $0) },
            sampleRate: 44100, synthesisSeconds: 0, capacitySplit: false)
        let bytes = try chunk.wav()
        XCTAssertEqual(String(data: bytes.prefix(4), encoding: .utf8), "RIFF")
        XCTAssertEqual(Array(bytes.suffix(6)), [0, 128, 0, 0, 255, 127])
    }
}
