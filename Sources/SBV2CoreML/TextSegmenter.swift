import Foundation

/// Sentence/newline boundaries first; a comma is allowed only for the first segment.
public struct TextSegmenter: Sendable {
    public let maximumCharacters: Int
    public let allowFirstComma: Bool
    public init(maximumCharacters: Int = 250, allowFirstComma: Bool = true) {
        self.maximumCharacters = max(2, maximumCharacters)
        self.allowFirstComma = allowFirstComma
    }
    public func split(_ text: String) -> [String] {
        var result: [String] = [], current = ""
        for c in text {
            current.append(c)
            let end = "。！？!?\n".contains(c)
            let firstComma = allowFirstComma && result.isEmpty && "、,，".contains(c)
            if end || firstComma || current.count >= maximumCharacters {
                append(current, to: &result); current = ""
            }
        }
        append(current, to: &result)
        return result
    }
    /// Full-buffer synthesis can share one inference across adjacent sentences.
    /// Capacity fallback still prefers punctuation if a batch exceeds the model limits.
    func batches(_ text: String) -> [String] {
        var sentences: [String] = [], sentence = ""
        for character in text {
            sentence.append(character)
            if "。！？!?\n".contains(character) || sentence.count >= maximumCharacters {
                sentences.append(sentence); sentence = ""
            }
        }
        if !sentence.isEmpty { sentences.append(sentence) }
        var result: [String] = [], current = ""
        for sentence in sentences {
            if !current.isEmpty && current.count + sentence.count > maximumCharacters {
                if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
                current = ""
            }
            current += sentence
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(current) }
        return result
    }
    private func append(_ text: String, to result: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Keep closing quotes and punctuation with the preceding spoken text.
        if trimmed.unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) }) && !result.isEmpty {
            result[result.count - 1] += trimmed
        } else { result.append(trimmed) }
    }
    /// Used only after a model capacity error. Preserve all characters and prefer a boundary.
    static func bisect(_ text: String) -> [String]? {
        let chars = Array(text)
        guard chars.count > 1 else { return nil }
        let midpoint = chars.count / 2
        let candidates = (1..<chars.count).filter { "。！？!?\n、,， ".contains(chars[$0 - 1]) }
        let point = candidates.min { abs($0 - midpoint) < abs($1 - midpoint) } ?? midpoint
        return [String(chars[..<point]), String(chars[point...])].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
