import Foundation
import NaturalLanguage

/// Языковой профиль для русского (и смешанного рус./англ.) текста.
/// Алгоритмы перенесены из pipeline без изменений — golden-тест на идентичность вывода проходит.
struct RussianProfile: LanguageProfile {

    let code = "ru"

    // MARK: - Токенизация

    /// Возвращает диапазоны предложений через `NLTokenizer(.sentence)`.
    /// Поведение идентично прямому вызову `enumerateTokens` в экстракторах.
    func sentenceRanges(in cleaned: String) -> [Range<String.Index>] {
        guard !cleaned.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = cleaned
        var ranges: [Range<String.Index>] = []
        tokenizer.enumerateTokens(in: cleaned.startIndex..<cleaned.endIndex) { range, _ in
            ranges.append(range)
            return true
        }
        return ranges
    }

    // MARK: - Детект заголовков

    private static let headingPatterns: [NSRegularExpression] = [
        "^#{1,3}\\s+\\S",
        "^(глава|часть|раздел)\\s+[0-9ivxlcdm\\.]+",
        "^(chapter|part|section)\\s+\\d+",
        "^\\d+(\\.\\d+)+\\s+\\S",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let specialSections: Set<String> = [
        "пролог", "эпилог", "предисловие", "введение", "заключение",
        "послесловие", "оглавление", "содержание", "аннотация", "благодарности",
        "prologue", "epilogue", "foreword", "afterword", "preface",
        "introduction", "conclusion", "contents",
    ]

    func isHeading(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        guard t.split(separator: " ").count <= 12 else { return false }
        if let last = t.last, ".!?…".contains(last) { return false }
        let lower = t.lowercased()
        let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == ":" })
            .first.map(String.init) ?? lower
        if Self.specialSections.contains(firstWord) { return true }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return Self.headingPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
    }

    // MARK: - Раскрытие для озвучки

    func expandForSpeech(_ sentence: String) -> String {
        var result = Self.stripLinks(sentence)
        result = Self.collapseDots(result)
        result = Self.expandListMarker(result)
        result = Self.expandNumbers(result)
        for (abbr, full) in Self.abbreviations {
            result = result.replacingOccurrences(of: abbr, with: full)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Аббревиатуры

    private static let abbreviations: [(String, String)] = [
        ("т. е.", "то есть"), ("т.е.", "то есть"),
        ("т. к.", "так как"), ("т.к.", "так как"),
        ("т. д.", "так далее"), ("т.д.", "так далее"),
        ("т. п.", "тому подобное"), ("т.п.", "тому подобное"),
        ("и др.", "и другие"),
        ("напр.", "например"),
        ("см.", "смотри"),
        ("№", "номер ")
    ]

    // MARK: - Ссылки

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func stripLinks(_ text: String) -> String {
        guard let detector = linkDetector else { return text }
        let full = NSRange(location: 0, length: (text as NSString).length)
        let matches = detector.matches(in: text, range: full)
        guard !matches.isEmpty else { return text }
        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: " ")
        }
        return mutable as String
    }

    // MARK: - Многоточия

    private static func collapseDots(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var dotRun = 0
        for scalar in text.unicodeScalars {
            if scalar == "." {
                dotRun += 1
                continue
            }
            if dotRun > 0 {
                out.append(dotRun >= 2 ? " " : ".")
                dotRun = 0
            }
            if scalar == "\u{2026}" {
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        if dotRun > 0 { out.append(dotRun >= 2 ? " " : ".") }
        return String(out)
    }

    // MARK: - Маркеры списков

    private static let listMarkerRegex =
        try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})[.)]\\s+(?=\\S)")

    private static let ordinalNeuter = [
        "", "первое", "второе", "третье", "четвёртое", "пятое",
        "шестое", "седьмое", "восьмое", "девятое", "десятое",
        "одиннадцатое", "двенадцатое", "тринадцатое", "четырнадцатое",
        "пятнадцатое", "шестнадцатое", "семнадцатое", "восемнадцатое",
        "девятнадцатое", "двадцатое",
    ]

    private static func expandListMarker(_ text: String) -> String {
        guard let re = listMarkerRegex else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: full) else { return text }
        let numStr = ns.substring(with: m.range(at: 1))
        guard let n = Int(numStr) else { return text }
        let word = (n >= 1 && n <= 20) ? ordinalNeuter[n] : integerToWords(numStr)
        return word + ", " + ns.substring(from: m.range.location + m.range.length)
    }

    // MARK: - Числа словами (русские числительные)

    private static let nUnits    = ["", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let nUnitsF   = ["", "одна", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let nTeens    = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
    private static let nTens     = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]
    private static let nHundreds = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"]
    private static let nDigit    = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]

    private static let scaleForms: [(String, String, String)] = [
        ("", "", ""),
        ("тысяча", "тысячи", "тысяч"),
        ("миллион", "миллиона", "миллионов"),
        ("миллиард", "миллиарда", "миллиардов"),
    ]
    private static let percentForms = ("процент", "процента", "процентов")

    private static func pluralForm(_ n: Int, _ forms: (String, String, String)) -> String {
        let n100 = n % 100
        if n100 >= 11 && n100 <= 14 { return forms.2 }
        switch n % 10 {
        case 1:       return forms.0
        case 2, 3, 4: return forms.1
        default:      return forms.2
        }
    }

    private static func group3Words(_ n: Int, feminine: Bool) -> [String] {
        var w: [String] = []
        let h = n / 100
        let rem = n % 100
        let t = rem / 10
        let u = rem % 10
        if h > 0 { w.append(nHundreds[h]) }
        if t == 1 {
            w.append(nTeens[u])
        } else {
            if t >= 2 { w.append(nTens[t]) }
            if u > 0 { w.append(feminine ? nUnitsF[u] : nUnits[u]) }
        }
        return w
    }

    static func integerToWords(_ digits: String) -> String {
        guard !digits.isEmpty else { return "" }
        if digits.count > 9 || Int(digits) == nil {
            return digits.compactMap { $0.wholeNumberValue }.map { nDigit[$0] }.joined(separator: " ")
        }
        let value = Int(digits)!
        if value == 0 { return "ноль" }
        var groups: [Int] = []
        var n = value
        while n > 0 { groups.append(n % 1000); n /= 1000 }
        var words: [String] = []
        for i in stride(from: groups.count - 1, through: 0, by: -1) {
            let g = groups[i]
            if g == 0 { continue }
            words += group3Words(g, feminine: i == 1)
            if i >= 1 { words.append(pluralForm(g, scaleForms[i])) }
        }
        return words.joined(separator: " ")
    }

    private static func numberWords(_ digits: String) -> String {
        digits.count > 9
            ? digits.compactMap { $0.wholeNumberValue }.map { nDigit[$0] }.joined(separator: " ")
            : integerToWords(digits)
    }

    private static func expandNumbers(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i].isNumber else { out.append(chars[i]); i += 1; continue }

            var parts: [String] = []
            var seps: [Character] = []
            var cur = ""
            var j = i
            while j < chars.count {
                if chars[j].isNumber {
                    cur.append(chars[j]); j += 1
                } else if (chars[j] == "." || chars[j] == ",") && j + 1 < chars.count && chars[j + 1].isNumber {
                    parts.append(cur); cur = ""; seps.append(chars[j]); j += 1
                } else { break }
            }
            parts.append(cur)

            var k = j
            while k < chars.count && chars[k] == " " { k += 1 }
            var percent = false
            if k < chars.count && chars[k] == "%" { percent = true; j = k + 1 }

            var tokens: [String] = []
            for (idx, p) in parts.enumerated() {
                if idx > 0 { tokens.append(seps[idx - 1] == "," ? "запятая" : "точка") }
                tokens.append(numberWords(p))
            }
            var phrase = tokens.joined(separator: " ")
            if percent {
                if parts.count == 1, let v = Int(parts[0]) {
                    phrase += " " + pluralForm(v, percentForms)
                } else {
                    phrase += " процента"
                }
            }
            out += phrase
            i = j
        }
        return out
    }
}
