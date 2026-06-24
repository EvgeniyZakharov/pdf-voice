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

    // MARK: - Шаблонный мусор и заголовки (портировано из навыка audiobook)

    /// Строки-шаблоны без полезного для озвучки текста — удаляются на ЛЮБОЙ
    /// позиции (в отличие от колонтитулов, которые ищутся только сверху/снизу).
    /// Источник правил: skill `audiobook` (TextCleaner), адаптировано под рус.+англ.:
    /// копирайт/правовые штампы, дата-штампы, «Page N»/«Стр. N», «N of N»/«N из M».
    private static let junkPatterns: [NSRegularExpression] = [
        "©.*\\d{4}",                 // © 2024 ...
        "^©",                        // строка, начинающаяся со знака копирайта
        "all rights reserved",
        "все права защищены",
        "^\\d{4}-\\d{2}-\\d{2}",     // ISO дата-штамп: 2026-06-24
        "^page\\s+\\d+\\s*$",        // Page 42
        "^стр\\.?\\s*\\d+\\s*$",     // Стр. 42 / стр 42
        "^страница\\s+\\d+\\s*$",    // Страница 42
        "^\\d+\\s+of\\s+\\d+\\s*$",  // 42 of 200
        "^\\d+\\s+из\\s+\\d+\\s*$",  // 42 из 200
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isJunkLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return junkPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
    }

    /// Заголовки глав/разделов: используются, чтобы НЕ склеивать заголовок с
    /// абзацем и давать паузу после него. Портировано из ChapterDetector
    /// (numbered / markdown / спец-разделы), адаптировано под русский.
    private static let headingPatterns: [NSRegularExpression] = [
        "^#{1,3}\\s+\\S",                              // markdown: #, ##, ###
        "^(глава|часть|раздел)\\s+[0-9ivxlcdm\\.]+",   // Глава 3 / Часть II / Раздел 1.2
        "^(chapter|part|section)\\s+\\d+",             // Chapter 3
        "^\\d+(\\.\\d+)+\\s+\\S",                      // 1.2 Название / 3.4.1 Название
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let specialSections: Set<String> = [
        "пролог", "эпилог", "предисловие", "введение", "заключение",
        "послесловие", "оглавление", "содержание", "аннотация", "благодарности",
        "prologue", "epilogue", "foreword", "afterword", "preface",
        "introduction", "conclusion", "contents",
    ]

    /// Похож ли текст на заголовок: короткая строка, не оканчивается завершающей
    /// пунктуацией, и либо это спец-раздел, либо совпадает с шаблоном главы.
    static func isHeadingText(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Заголовок — короткий; длинная строка это проза.
        guard t.split(separator: " ").count <= 12 else { return false }
        // Заголовки не заканчиваются точкой/!/?/…
        if let last = t.last, ".!?…".contains(last) { return false }
        let lower = t.lowercased()
        let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == ":" })
            .first.map(String.init) ?? lower
        if specialSections.contains(firstWord) { return true }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return headingPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
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
            if isLeaderLine(text) || isJunkLine(text) {
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
        result = expandListMarker(result)   // "1." / "1)" в начале -> "первое, "
        result = expandNumbers(result)      // цифры -> слова
        for (abbr, full) in abbreviations {
            result = result.replacingOccurrences(of: abbr, with: full)
        }
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Числа словами (русские числительные)

    private static let nUnits    = ["", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let nUnitsF   = ["", "одна", "две", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let nTeens    = ["десять", "одиннадцать", "двенадцать", "тринадцать", "четырнадцать", "пятнадцать", "шестнадцать", "семнадцать", "восемнадцать", "девятнадцать"]
    private static let nTens     = ["", "", "двадцать", "тридцать", "сорок", "пятьдесят", "шестьдесят", "семьдесят", "восемьдесят", "девяносто"]
    private static let nHundreds = ["", "сто", "двести", "триста", "четыреста", "пятьсот", "шестьсот", "семьсот", "восемьсот", "девятьсот"]
    private static let nDigit    = ["ноль", "один", "два", "три", "четыре", "пять", "шесть", "семь", "восемь", "девять"]
    private static let ordinalNeuter = ["", "первое", "второе", "третье", "четвёртое", "пятое", "шестое", "седьмое", "восьмое", "девятое", "десятое", "одиннадцатое", "двенадцатое", "тринадцатое", "четырнадцатое", "пятнадцатое", "шестнадцатое", "семнадцатое", "восемнадцатое", "девятнадцатое", "двадцатое"]

    /// Формы разрядов: (1, 2–4, 5–0 и 11–14).
    private static let scaleForms: [(String, String, String)] = [
        ("", "", ""),
        ("тысяча", "тысячи", "тысяч"),
        ("миллион", "миллиона", "миллионов"),
        ("миллиард", "миллиарда", "миллиардов"),
    ]
    private static let percentForms = ("процент", "процента", "процентов")

    /// Выбор формы существительного по числу (1 рубль / 2 рубля / 5 рублей).
    private static func pluralForm(_ n: Int, _ forms: (String, String, String)) -> String {
        let n100 = n % 100
        if n100 >= 11 && n100 <= 14 { return forms.2 }
        switch n % 10 {
        case 1:       return forms.0
        case 2, 3, 4: return forms.1
        default:      return forms.2
        }
    }

    /// Слова для трёхзначной группы (с учётом рода единиц: тысяча — женский).
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

    /// Целое (строка цифр) → слова. До 9 цифр; длиннее — почифренно (телефоны, коды).
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

    private static let listMarkerRegex =
        try? NSRegularExpression(pattern: "^\\s*(\\d{1,3})[.)]\\s+(?=\\S)")

    /// «1. Купить…» / «1) Купить…» в начале пункта → «первое, Купить…».
    static func expandListMarker(_ text: String) -> String {
        guard let re = listMarkerRegex else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = re.firstMatch(in: text, range: full) else { return text }
        let numStr = ns.substring(with: m.range(at: 1))
        guard let n = Int(numStr) else { return text }
        let word = (n >= 1 && n <= 20) ? ordinalNeuter[n] : integerToWords(numStr)
        return word + ", " + ns.substring(from: m.range.location + m.range.length)
    }

    /// Заменяет числа в тексте словами. Десятичные/составные («2.1», «3,14»)
    /// читаются через «точка»/«запятая»; «50%» — с правильной формой «процентов».
    static func expandNumbers(_ text: String) -> String {
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

            // Необязательный завершающий процент: "50 %" / "50%".
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

    private static func numberWords(_ digits: String) -> String {
        digits.count > 9
            ? digits.compactMap { $0.wholeNumberValue }.map { nDigit[$0] }.joined(separator: " ")
            : integerToWords(digits)
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
