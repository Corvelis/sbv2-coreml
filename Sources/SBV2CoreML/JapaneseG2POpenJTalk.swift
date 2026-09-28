import Foundation
import SBV2Native

final class JapaneseG2POpenJTalk {
    struct G2PResult {
        let phonemes: [String]
        let phonemeIds: [Int64]
        let tones: [Int64]
        let word2ph: [Int]
        let katakana: String
        let originalText: String
    }

    private static let shared = JapaneseG2POpenJTalk()
    private var openJTalk: OpenJTalkEngine?
    private var isInitialized = false
    private var dictionaryPath: String?

    static func initialize(dicPath: String) -> Bool {
        return shared.initialize(dicPath: dicPath)
    }

    private func initialize(dicPath: String) -> Bool {
        if isInitialized && dictionaryPath == dicPath { return true }
        let engine = OpenJTalkEngine()
        guard engine.initialize(dicPath: dicPath) else {
            return false
        }
        openJTalk = engine
        isInitialized = true
        dictionaryPath = dicPath
        return true
    }

    static func convertTextToPhonemes(text: String, tokenCount: Int) -> G2PResult? {
        return shared.convertTextToPhonemes(text: text, tokenCount: tokenCount)
    }

    private func convertTextToPhonemes(text: String, tokenCount: Int) -> G2PResult? {
        guard isInitialized, let openJTalk = openJTalk else {
            return nil
        }
        guard let features = openJTalk.runFrontend(text: text) else { return nil }
        guard let labels = openJTalk.makeLabel(features: features) else { return nil }
        return extractPhonemesAndTonesFromLabels(labels: labels, tokenCount: tokenCount, features: features)
    }

    private func extractPhonemesAndTonesFromLabels(
        labels: [String],
        tokenCount: Int,
        features: [[String: Any]]
    ) -> G2PResult {
        let prosodyPhonemes = generateProsodyPhonemes(labels: labels)
        let phoneToneListWoPunct = interpretProsodySymbols(prosodies: prosodyPhonemes)
        let sepPhonemes = generatePhonemeListWithPunctuation(features: features)
        var phoneWPunct: [String] = []
        for list in sepPhonemes { phoneWPunct.append(contentsOf: list) }
        let phoneToneList = alignTones(phonesWithPunct: phoneWPunct, phoneToneList: phoneToneListWoPunct)

        var finalPhonemes: [String] = ["_"]
        var finalTones: [Int64] = [0]
        for (phone, tone) in phoneToneList {
            finalPhonemes.append(phone)
            finalTones.append(Int64(tone))
        }
        finalPhonemes.append("_")
        finalTones.append(0)

        let phonemeIds = finalPhonemes.map { getPhonemeId($0) }
        let word2ph = calculateMorphemeBasedWord2ph(features: features, sepPhonemes: sepPhonemes, tokenCount: tokenCount)

        let katakana = features.compactMap { $0["pron"] as? String }
            .map { $0.replacingOccurrences(of: "\u{2019}", with: "").replacingOccurrences(of: "'", with: "") }
            .joined()
        let originalText = features.compactMap { $0["string"] as? String }.joined()

        return G2PResult(
            phonemes: finalPhonemes,
            phonemeIds: phonemeIds,
            tones: finalTones,
            word2ph: word2ph,
            katakana: katakana,
            originalText: originalText
        )
    }

    private func generateProsodyPhonemes(labels: [String]) -> [String] {
        let p3 = try! NSRegularExpression(pattern: "-([^+]+)\\+")
        let a1 = try! NSRegularExpression(pattern: "/A:([0-9\\-]+)\\+")
        let a2 = try! NSRegularExpression(pattern: "\\+(\\d+)\\+")
        let a3 = try! NSRegularExpression(pattern: "\\+(\\d+)/")
        let e3 = try! NSRegularExpression(pattern: "!(\\d+)_")
        let f1 = try! NSRegularExpression(pattern: "/F:(\\d+)_")

        var phones: [String] = []
        let n = labels.count

        for i in 0..<n {
            let labCurr = labels[i]
            guard let p3Match = match(regex: p3, in: labCurr, group: 1) else { continue }
            var p3Val = p3Match

            if ["A","E","I","O","U"].contains(p3Val) {
                p3Val = p3Val.lowercased()
            }

            if p3Val == "sil" {
                if i == 0 {
                    phones.append("^")
                } else if i == n - 1 {
                    let e3Val = match(regex: e3, in: labCurr, group: 1).flatMap { Int($0) } ?? -50
                    phones.append(e3Val == 1 ? "?" : "$")
                }
                continue
            } else if p3Val == "pau" {
                phones.append("_")
                continue
            } else {
                phones.append(p3Val)
            }

            let a1Val = match(regex: a1, in: labCurr, group: 1).flatMap { Int($0) } ?? -50
            let a2Val = match(regex: a2, in: labCurr, group: 1).flatMap { Int($0) } ?? -50
            let a3Val = match(regex: a3, in: labCurr, group: 1).flatMap { Int($0) } ?? -50
            let f1Val = match(regex: f1, in: labCurr, group: 1).flatMap { Int($0) } ?? -50

            let a2Next = (i + 1 < n) ? (match(regex: a2, in: labels[i + 1], group: 1).flatMap { Int($0) } ?? -50) : -50

            if a3Val == 1 && a2Next == 1 && ["a","e","i","o","u","A","E","I","O","U","N","cl"].contains(p3Val) {
                phones.append("#")
            } else if a1Val == 0 && a2Next == a2Val + 1 && a2Val != f1Val {
                phones.append("]")
            } else if a2Val == 1 && a2Next == 2 {
                phones.append("[")
            }
        }

        return phones
    }

    private func interpretProsodySymbols(prosodies: [String]) -> [(String, Int)] {
        var result: [(String, Int)] = []
        var currentPhrase: [(String, Int)] = []
        var currentTone = 0

        for letter in prosodies {
            if letter == "^" {
                continue
            } else if ["$", "?", "_", "#"].contains(letter) {
                result.append(contentsOf: fixPhoneTones(phones: currentPhrase))
                currentPhrase.removeAll()
                currentTone = 0
            } else if letter == "[" {
                currentTone += 1
            } else if letter == "]" {
                currentTone -= 1
            } else {
                let phoneme = (letter == "cl") ? "q" : letter
                currentPhrase.append((phoneme, currentTone))
            }
        }

        if !currentPhrase.isEmpty {
            result.append(contentsOf: fixPhoneTones(phones: currentPhrase))
        }
        return result
    }

    private func fixPhoneTones(phones: [(String, Int)]) -> [(String, Int)] {
        let tones = Set(phones.map { $0.1 })
        if tones.count == 1 {
            if tones != [0] {
                return phones.map { ($0.0, 0) }
            }
            return phones
        }
        if tones.count == 2 {
            if tones == [0, 1] {
                return phones
            }
            if tones == [-1, 0] {
                return phones.map { ($0.0, $0.1 == -1 ? 0 : 1) }
            }
            return phones.map { ($0.0, $0.1 <= 0 ? 0 : 1) }
        }
        return phones.map { ($0.0, $0.1 <= 0 ? 0 : 1) }
    }

    private func generatePhonemeListWithPunctuation(features: [[String: Any]]) -> [[String]] {
        struct MorphemeInfo { let string: String; let pron: String }
        var morphemes: [MorphemeInfo] = []
        for feature in features {
            let string = feature["string"] as? String ?? ""
            var pron = feature["pron"] as? String ?? ""
            pron = pron.replacingOccurrences(of: "\u{2019}", with: "")
            pron = pron.replacingOccurrences(of: "\u{2018}", with: "")
            pron = pron.replacingOccurrences(of: "'", with: "")
            pron = pron.replacingOccurrences(of: "`", with: "")
            pron = pron.replacingOccurrences(of: "´", with: "")
            morphemes.append(MorphemeInfo(string: string, pron: pron))
        }

        var sepPhonemes: [[String]] = []
        for morpheme in morphemes {
            sepPhonemes.append(kataToPhonemeList(kata: morpheme.pron))
        }
        return handleLong(sepPhonemes: sepPhonemes)
    }

    private func alignTones(phonesWithPunct: [String], phoneToneList: [(String, Int)]) -> [(String, Int)] {
        let punctuations: Set<String> = ["!", "?", "…", ",", ".", "'", "-"]
        var result: [(String, Int)] = []
        var toneIndex = 0
        for phone in phonesWithPunct {
            if toneIndex >= phoneToneList.count {
                result.append((phone, 0))
            } else if phone == phoneToneList[toneIndex].0 {
                result.append((phone, phoneToneList[toneIndex].1))
                toneIndex += 1
            } else if punctuations.contains(phone) {
                result.append((phone, 0))
            } else {
                result.append((phone, 0))
            }
        }
        return result
    }

    private func handleLong(sepPhonemes: [[String]]) -> [[String]] {
        let vowels: Set<String> = ["a", "i", "u", "e", "o", "N"]
        var result: [[String]] = []
        for i in 0..<sepPhonemes.count {
            var phonemes = sepPhonemes[i]
            if phonemes.isEmpty {
                result.append(phonemes)
                continue
            }
            if phonemes[0] == "ー" {
                if i != 0, let prev = result.last?.last, vowels.contains(prev) {
                    phonemes[0] = prev
                } else {
                    phonemes[0] = "-"
                }
            }
            if phonemes.count > 1 {
                for j in 1..<phonemes.count {
                    if phonemes[j] == "ー" {
                        let prev = phonemes[j - 1]
                        phonemes[j] = prev.isEmpty ? "-" : String(prev.suffix(1))
                    }
                }
            }
            result.append(phonemes)
        }
        return result
    }

    private func kataToPhonemeList(kata: String) -> [String] {
        let puncts: Set<Character> = ["!", "?", "…", ",", ".", "'", "-", "、", "。", "！", "？"]
        var kataClean = kata
        kataClean = kataClean.replacingOccurrences(of: "\u{2019}", with: "")
        kataClean = kataClean.replacingOccurrences(of: "\u{2018}", with: "")
        kataClean = kataClean.replacingOccurrences(of: "'", with: "")
        kataClean = kataClean.replacingOccurrences(of: "`", with: "")
        kataClean = kataClean.replacingOccurrences(of: "´", with: "")

        if kataClean.allSatisfy({ puncts.contains($0) }) {
            return kataClean.map { String($0) }
        }

        let moraMap: [String: [String]] = [
            "ア": ["a"], "イ": ["i"], "ウ": ["u"], "エ": ["e"], "オ": ["o"],
            "カ": ["k","a"], "キ": ["k","i"], "ク": ["k","u"], "ケ": ["k","e"], "コ": ["k","o"],
            "ガ": ["g","a"], "ギ": ["g","i"], "グ": ["g","u"], "ゲ": ["g","e"], "ゴ": ["g","o"],
            "サ": ["s","a"], "シ": ["sh","i"], "ス": ["s","u"], "セ": ["s","e"], "ソ": ["s","o"],
            "ザ": ["z","a"], "ジ": ["j","i"], "ズ": ["z","u"], "ゼ": ["z","e"], "ゾ": ["z","o"],
            "タ": ["t","a"], "チ": ["ch","i"], "ツ": ["ts","u"], "テ": ["t","e"], "ト": ["t","o"],
            "ダ": ["d","a"], "ヂ": ["j","i"], "ヅ": ["z","u"], "デ": ["d","e"], "ド": ["d","o"],
            "ナ": ["n","a"], "ニ": ["n","i"], "ヌ": ["n","u"], "ネ": ["n","e"], "ノ": ["n","o"],
            "ハ": ["h","a"], "ヒ": ["h","i"], "フ": ["h","u"], "ヘ": ["h","e"], "ホ": ["h","o"],
            "バ": ["b","a"], "ビ": ["b","i"], "ブ": ["b","u"], "ベ": ["b","e"], "ボ": ["b","o"],
            "パ": ["p","a"], "ピ": ["p","i"], "プ": ["p","u"], "ペ": ["p","e"], "ポ": ["p","o"],
            "マ": ["m","a"], "ミ": ["m","i"], "ム": ["m","u"], "メ": ["m","e"], "モ": ["m","o"],
            "ヤ": ["y","a"], "ユ": ["y","u"], "ヨ": ["y","o"],
            "ラ": ["r","a"], "リ": ["r","i"], "ル": ["r","u"], "レ": ["r","e"], "ロ": ["r","o"],
            "ワ": ["w","a"], "ヲ": ["w","o"],
            "ン": ["N"], "ッ": ["q"],
            "キャ": ["ky","a"], "キュ": ["ky","u"], "キョ": ["ky","o"],
            "シャ": ["sh","a"], "シュ": ["sh","u"], "ショ": ["sh","o"],
            "チャ": ["ch","a"], "チュ": ["ch","u"], "チョ": ["ch","o"],
            "ニャ": ["ny","a"], "ニュ": ["ny","u"], "ニョ": ["ny","o"],
            "ヒャ": ["hy","a"], "ヒュ": ["hy","u"], "ヒョ": ["hy","o"],
            "ミャ": ["my","a"], "ミュ": ["my","u"], "ミョ": ["my","o"],
            "リャ": ["ry","a"], "リュ": ["ry","u"], "リョ": ["ry","o"],
            "ギャ": ["gy","a"], "ギュ": ["gy","u"], "ギョ": ["gy","o"],
            "ジャ": ["j","a"], "ジュ": ["j","u"], "ジョ": ["j","o"],
            "ビャ": ["by","a"], "ビュ": ["by","u"], "ビョ": ["by","o"],
            "ピャ": ["py","a"], "ピュ": ["py","u"], "ピョ": ["py","o"],
        ]

        var result: [String] = []
        let chars = Array(kataClean)
        var i = 0
        while i < chars.count {
            if i + 1 < chars.count {
                let twoChar = String(chars[i]) + String(chars[i + 1])
                if let mora = moraMap[twoChar] {
                    result.append(contentsOf: mora)
                    i += 2
                    continue
                }
            }
            let oneChar = String(chars[i])
            if let mora = moraMap[oneChar] {
                result.append(contentsOf: mora)
            } else if oneChar == "ー" {
                if let last = result.last {
                    result.append(last)
                } else {
                    result.append("-")
                }
            } else if let ch = oneChar.first, puncts.contains(ch) {
                result.append(oneChar)
            }
            i += 1
        }
        return result
    }

    private func getPhonemeId(_ phoneme: String) -> Int64 {
        let phonemeList = [
            "_",
            "AA","E","EE","En","N","OO","V","a","a:","aa","ae","ah","ai","an",
            "ang","ao","aw","ay","b","by","c","ch","d","dh","dy","e","e:","eh",
            "ei","en","eng","er","ey","f","g","gy","h","hh","hy","i","i:","i0",
            "ia","ian","iang","iao","ie","ih","in","ing","iong","ir","iu","iy",
            "j","jh","k","ky","l","m","my","n","ng","ny","o","o:","ong","ou",
            "ow","oy","p","py","q","r","ry","s","sh","t","th","ts","ty","u",
            "u:","ua","uai","uan","uang","uh","ui","un","uo","uw","v","van","ve",
            "vn","w","x","y","z","zh","zy",
            "!", "?", "…", ",", ".", "'", "-", "SP", "UNK"
        ]
        if let idx = phonemeList.firstIndex(of: phoneme) {
            return Int64(idx)
        }
        return 0
    }

    private func calculateMorphemeBasedWord2ph(
        features: [[String: Any]],
        sepPhonemes: [[String]],
        tokenCount: Int
    ) -> [Int] {
        let puncts: Set<Character> = ["!", "?", "…", ",", ".", "'", "-"]
        var sepTokenized: [[String]] = []
        for feature in features {
            let morpheme = feature["string"] as? String ?? ""
            if morpheme.count == 1, let ch = morpheme.first, puncts.contains(ch) {
                sepTokenized.append([morpheme])
            } else {
                sepTokenized.append(morpheme.map { String($0) })
            }
        }

        var word2ph: [Int] = [1]
        for (tokens, phonemes) in zip(sepTokenized, sepPhonemes) {
            let dist = distributePhonemes(charCount: tokens.count, phonemeCount: phonemes.count)
            word2ph.append(contentsOf: dist)
        }
        word2ph.append(1)
        return word2ph
    }

    private func distributePhonemes(charCount: Int, phonemeCount: Int) -> [Int] {
        if charCount == 0 { return [] }
        var perChar = Array(repeating: 0, count: charCount)
        for _ in 0..<phonemeCount {
            if let minVal = perChar.min(), let idx = perChar.firstIndex(of: minVal) {
                perChar[idx] += 1
            }
        }
        return perChar
    }

    private func match(regex: NSRegularExpression, in text: String, group: Int) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        guard group < match.numberOfRanges else { return nil }
        if let range = Range(match.range(at: group), in: text) {
            return String(text[range])
        }
        return nil
    }

    static func release() {
        shared.openJTalk?.release()
        shared.openJTalk = nil
        shared.isInitialized = false
    }
}
