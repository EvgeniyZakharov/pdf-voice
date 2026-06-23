import Foundation

/// Очистка текста PDF перед озвучкой: колонтитулы, номера страниц, переносы,
/// раскрытие аббревиатур. Работает построчно и сохраняет карту смещений UTF-16,
/// чтобы подсветка оставалась привязанной к исходным координатам страницы.
enum TextNormalizer {

    /// Строка страницы с её UTF-16-смещением в `PDFPage.string`.
    struct PageLine {
        let text: String
        let startUTF16: Int
    }

    // UTF-16 коды служебных символов.
    private static let space: UInt16 = 0x20
    private static let tab: UInt16 = 0x09
    private static let cr: UInt16 = 0x0D
    private static let newline: UInt16 = 0x0A
    private static let hyphen: UInt16 = 0x2D

    // MARK: - Разбор на строки

    /// Бьёт исходную строку страницы на строки, запоминая смещение начала каждой.
    static func lines(of raw: String) -> [PageLine] {
        guard !raw.isEmpty else { return [] }
        let units = Array(raw.utf16)
        var result: [PageLine] = []
        var lineStart = 0
        var i = 0
        while i <= units.count {
            if i == units.count || units[i] == newline {
                let slice = Array(units[lineStart..<i])
                let text = slice.isEmpty ? "" : String(utf16CodeUnits: slice, count: slice.count)
                result.append(PageLine(text: text, startUTF16: lineStart))
                lineStart = i + 1
            }
            i += 1
        }
        return result
    }

    // MARK: - Детект колонтитулов

    /// Нормализованный ключ строки: trim + lowercase + схлопывание цифр в «#».
    /// Так «Page 12» и «Page 13» дают один ключ «page #».
    static func normalizedKey(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        var out = ""
        var lastWasDigit = false
        for ch in trimmed {
            if ch.isNumber {
                if !lastWasDigit { out.append("#") }
                lastWasDigit = true
            } else {
                lastWasDigit = false
                if ch.isWhitespace {
                    if out.last != " " { out.append(" ") }
                } else {
                    out.append(ch)
                }
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Строка-лидер: содержит «............» (5+ точек подряд) — оглавление, индекс,
    /// заполнители. В обычной прозе такого не бывает, поэтому выбрасываем целиком.
    static func isLeaderLine(_ s: String) -> Bool {
        var run = 0
        for ch in s {
            if ch == "." {
                run += 1
                if run >= 5 { return true }
            } else {
                run = 0
            }
        }
        return false
    }

    /// Строка состоит только из числа (плюс возможные пробелы/тире/точки/палки) —
    /// почти наверняка номер страницы.
    static func isPageNumberLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        var digits = 0
        for ch in t {
            if ch.isNumber { digits += 1 }
            else if ch == "." || ch == "-" || ch == "–" || ch == "—" || ch == "|" || ch == " " { continue }
            else { return false }
        }
        return digits > 0
    }

    /// Ищет повторяющиеся строки в зоне верх/низ страниц (колонтитулы).
    static func detectBoilerplate(pages: [[PageLine]], pageCount: Int) -> Set<String> {
        guard pageCount >= 4 else { return [] }
        var counts: [String: Int] = [:]
        for lines in pages {
            let n = lines.count
            guard n > 4 else { continue }
            var seen = Set<String>()
            for i in 0..<n where i < 2 || i >= n - 2 {
                let key = normalizedKey(lines[i].text)
                guard !key.isEmpty else { continue }
                if seen.insert(key).inserted { counts[key, default: 0] += 1 }
            }
        }
        let threshold = max(3, pageCount / 5)
        return Set(counts.filter { $0.value >= threshold }.keys)
    }

    /// Индексы строк страницы, которые надо выбросить.
    /// Строки-лидеры (оглавление/индексы) — на любой позиции; колонтитулы и
    /// номера страниц — только в зоне верх/низ и только на нормальных страницах.
    static func droppedIndices(lines: [PageLine], boilerplate: Set<String>) -> Set<Int> {
        let n = lines.count
        var dropped: Set<Int> = []
        let regionEnabled = n > 4   // мелкие страницы не трогаем по колонтитулам
        for i in 0..<n {
            let text = lines[i].text
            if isLeaderLine(text) {
                dropped.insert(i)
                continue
            }
            guard regionEnabled, i < 2 || i >= n - 2 else { continue }
            if isPageNumberLine(text) {
                dropped.insert(i)
            } else {
                let key = normalizedKey(text)
                if !key.isEmpty, boilerplate.contains(key) { dropped.insert(i) }
            }
        }
        return dropped
    }

    // MARK: - Сборка очищенного текста + карта смещений

    /// Собирает очищенный текст страницы из оставленных строк:
    /// склейка переносов по дефису, перевод строки → пробел, схлопывание пробелов.
    /// Возвращает текст и параллельный массив исходных UTF-16-смещений по символам.
    static func cleanPage(_ lines: [PageLine], dropped: Set<Int>) -> (String, [Int]) {
        var units: [UInt16] = []
        var orig: [Int] = []

        func appendSpace(at index: Int) {
            if units.isEmpty { return }       // не начинаем с пробела
            if units.last == space { return } // схлопываем
            units.append(space)
            orig.append(index)
        }

        for (idx, line) in lines.enumerated() where !dropped.contains(idx) {
            let lu = Array(line.text.utf16)
            var end = lu.count
            var joinNext = false
            if end > 0, lu[end - 1] == hyphen {  // "сло-" + перенос → склейка
                joinNext = true
                end -= 1
            }
            var k = 0
            while k < end {
                let u = lu[k]
                if u == space || u == tab || u == cr {
                    appendSpace(at: line.startUTF16 + k)
                } else {
                    units.append(u)
                    orig.append(line.startUTF16 + k)
                }
                k += 1
            }
            if !joinNext {
                appendSpace(at: line.startUTF16 + lu.count)
            }
        }

        if units.last == space {
            units.removeLast()
            orig.removeLast()
        }
        let cleaned = units.isEmpty ? "" : String(utf16CodeUnits: units, count: units.count)
        return (cleaned, orig)
    }

    // MARK: - Раскрытие аббревиатур (для озвучки)

    /// Безопасные, не зависящие от падежа замены. Числа→слова — в бэклоге
    /// (русские числительные склоняются, требуют отдельной грамматики).
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

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Вырезает ссылки на сайты и email — их незачем читать вслух.
    /// `NSDataDetector` ловит http(s)://, www., голые домены и mailto.
    static func stripLinks(_ text: String) -> String {
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

    /// Применяется к тексту предложения непосредственно перед озвучкой.
    /// Не влияет на диапазон подсветки — он указывает на исходный фрагмент.
    static func expandForSpeech(_ text: String) -> String {
        var result = stripLinks(text)
        result = collapseDots(result)
        for (abbr, full) in abbreviations {
            result = result.replacingOccurrences(of: abbr, with: full)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Схлопывает многоточия и короткие лидеры (2+ точки подряд, символ «…»)
    /// в один пробел, чтобы синтезатор не читал «точка-точка-точка».
    private static func collapseDots(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var dotRun = 0
        for scalar in text.unicodeScalars {
            if scalar == "." {
                dotRun += 1
                continue
            }
            if dotRun > 0 {
                out.append(dotRun >= 2 ? " " : ".")  // одиночная точка сохраняется
                dotRun = 0
            }
            if scalar == "\u{2026}" {  // «…»
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        if dotRun > 0 { out.append(dotRun >= 2 ? " " : ".") }
        return String(out)
    }
}
