import Foundation
import SBV2Native
import XCTest

final class ModelPreparationTests: XCTestCase {
    func testFailedBertPreparationFinishesConcurrentWorkBeforeSessionRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let blocks = root.appendingPathComponent("coreml_blocks")
        try FileManager.default.createDirectory(at: blocks, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try ["prefix.0", "group.1-23-conv"].map { name -> [String: Any] in
            // Both entries exist, but contain invalid Core ML packages.
            // Preparation must report the error and safely join the background load.
            try FileManager.default.createDirectory(
                at: blocks.appendingPathComponent(name + ".mlpackage"), withIntermediateDirectories: true)
            return ["block": name, "mlpackage": name + ".mlpackage",
                    "coreml_input_names": ["input"], "coreml_output_names": ["output"]]
        }
        try JSONSerialization.data(withJSONObject: ["blocks": entries])
            .write(to: blocks.appendingPathComponent("coreml_bert_blocks_manifest.json"))
        let session = try XCTUnwrap(StyleBertVits2CoreMLBert.createSession(withBertPath: root.path))
        var concurrentWorkFinished = false
        let prepared = StyleBertVits2CoreMLBert.prepareSession(session) {
            concurrentWorkFinished = true
        }
        XCTAssertTrue(concurrentWorkFinished)
        XCTAssertFalse(prepared)
        XCTAssertTrue(StyleBertVits2CoreMLBert.lastError().contains("compile failed"))
        StyleBertVits2CoreMLBert.releaseSession(session)
    }
}
