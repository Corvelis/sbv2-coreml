import Foundation
import SBV2Native

final class BertTokenizer {
    struct TokenizerOutput {
        let tokenIds: [Int64]
        let attentionMask: [Int64]
    }

    private let vocab: [String: Int]

    private static let clsToken = "[CLS]"
    private static let sepToken = "[SEP]"
    private static let unkToken = "[UNK]"

    init(vocabPath: String) throws {
        let contents = try String(contentsOfFile: vocabPath, encoding: .utf8)
        var map: [String: Int] = [:]
        var index = 0
        contents.enumerateLines { line, _ in
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty {
                map[token] = index
            }
            index += 1
        }
        self.vocab = map
    }

    func tokenize(_ text: String) throws -> TokenizerOutput {
        guard let clsId = vocab[Self.clsToken], let sepId = vocab[Self.sepToken] else {
            throw NSError(domain: "BertTokenizer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing CLS/SEP tokens"])
        }
        let unkId = vocab[Self.unkToken] ?? 0

        var tokens: [Int] = [clsId]
        for char in text {
            let charStr = String(char)
            let tokenId = vocab[charStr] ?? unkId
            tokens.append(tokenId)
        }
        tokens.append(sepId)

        let tokenIds = tokens.map { Int64($0) }
        let attentionMask = Array(repeating: Int64(1), count: tokenIds.count)

        return TokenizerOutput(tokenIds: tokenIds, attentionMask: attentionMask)
    }
}
