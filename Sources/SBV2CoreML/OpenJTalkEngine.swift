import Foundation
import SBV2Native

final class OpenJTalkEngine {
    private var handle: UnsafeMutableRawPointer?

    func initialize(dicPath: String) -> Bool {
        if handle != nil {
            return true
        }
        let h = StyleBertVits2OpenJTalkBridge.initialize(dicPath: dicPath)
        if h == nil {
            return false
        }
        handle = h
        return true
    }

    func runFrontend(text: String) -> [[String: Any]]? {
        guard let handle = handle else {
            return nil
        }
        let result = StyleBertVits2OpenJTalkBridge.runFrontend(handle, text: text)
        return result.map { $0 as [String: Any] }
    }

    func makeLabel(features: [[String: Any]]) -> [String]? {
        guard let handle = handle else {
            return nil
        }
        let result = StyleBertVits2OpenJTalkBridge.makeLabel(handle, features: features)
        return result
    }

    func release() {
        if let handle = handle {
            StyleBertVits2OpenJTalkBridge.releaseHandle(handle)
            self.handle = nil
        }
    }
}
