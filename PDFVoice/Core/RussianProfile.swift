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

    // MARK: - Словарь ударений

    /// Слово в нижнем регистре → 0-based индекс ударной гласной (по Characters внутри слова).
    /// Только однозначные слова — омографы (за́мок/замо́к) НЕ включены.
    private static let stressDictionary: [String: Int] = [
        "звонит":   4,
        "позвонит": 6,
        "включит":  5,
        "повторит": 6,
        "облегчит": 6,
        "договор":  5,
        "каталог":  5,
        "квартал":  5,
        "километр": 5,
        "жалюзи":   5,
        "щавель":   3,
        "туфля":    1,
        "красивее": 4,
        "банты":    1,
        "торты":    1,
        "средства": 2,
        "баловать": 5,
        "цемент":   3,
        "столяр":   4,
        "кухонный": 1,
    ]

    private static let russianVowels: Set<Character> =
        ["а", "о", "у", "ы", "э", "я", "ё", "ю", "и", "е",
         "А", "О", "У", "Ы", "Э", "Я", "Ё", "Ю", "И", "Е"]

    // MARK: - Рендер с ударениями

    func render(_ raw: String) -> SpokenMarkup {
        let text = expandForSpeech(raw)
        var stresses: [Int] = []

        // Итерируем по Characters, собирая слова (кириллица + латиница).
        // Для каждого слова ищем ударение в словаре и вычисляем UTF-16-смещение.
        var wordStart: String.Index? = nil

        func processWord(from wordStartIdx: String.Index, to wordEndIdx: String.Index) {
            let wordChars = String(text[wordStartIdx..<wordEndIdx])
            let key = wordChars.lowercased()
            guard let stressCharIndex = Self.stressDictionary[key] else { return }
            // Найти i-й Character слова и его UTF-16 позицию в text.
            var charIdx = wordChars.startIndex
            var charCount = 0
            while charIdx < wordChars.endIndex && charCount < stressCharIndex {
                wordChars.formIndex(after: &charIdx)
                charCount += 1
            }
            guard charIdx < wordChars.endIndex else { return }
            let stressedChar = wordChars[charIdx]
            // Защита: убеждаемся, что символ — гласная.
            guard Self.russianVowels.contains(stressedChar) else { return }
            // Пересчёт смещения: позиция начала слова в text + смещение внутри слова.
            guard let wordStartUTF16 = wordStartIdx.samePosition(in: text.utf16),
                  let charUTF16 = charIdx.samePosition(in: wordChars.utf16) else { return }
            let wordOffsetInText = text.utf16.distance(
                from: text.utf16.startIndex,
                to: wordStartUTF16
            )
            let charOffsetInWord = wordChars.utf16.distance(
                from: wordChars.utf16.startIndex,
                to: charUTF16
            )
            stresses.append(wordOffsetInText + charOffsetInWord)
        }

        var idx = text.startIndex
        while idx < text.endIndex {
            let ch = text[idx]
            let isWordChar = ch.isLetter
            if isWordChar {
                if wordStart == nil { wordStart = idx }
            } else {
                if let ws = wordStart {
                    processWord(from: ws, to: idx)
                    wordStart = nil
                }
            }
            text.formIndex(after: &idx)
        }
        if let ws = wordStart {
            processWord(from: ws, to: text.endIndex)
        }

        return SpokenMarkup(text: text, stresses: stresses.sorted())
    }

    // MARK: - Раскрытие для озвучки

    func expandForSpeech(_ sentence: String) -> String {
        var result = Self.stripLinks(sentence)
        result = Self.collapseDots(result)
        result = Self.expandListMarker(result)
        result = Self.expandUnits(result)
        result = Self.expandNumbers(result)
        result = Self.expandCityPrefix(result)
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
        ("рис.", "рисунок"),
        ("табл.", "таблица"),
        ("гл.", "глава"),
        ("рус.", "русский"),
        ("англ.", "английский"),
        ("букв.", "буквально"),
        ("№", "номер ")
    ]

    // MARK: - Единицы измерения

    private static let unitForms: [(pattern: String, forms: (String, String, String))] = [
        ("кг",  ("килограмм",  "килограмма",  "килограммов")),
        ("км",  ("километр",   "километра",   "километров")),
        ("см",  ("сантиметр",  "сантиметра",  "сантиметров")),
        ("мм",  ("миллиметр",  "миллиметра",  "миллиметров")),
        ("мл",  ("миллилитр",  "миллилитра",  "миллилитров")),
    ]

    // Compiled once: «(digits) UNIT» where UNIT is NOT followed by letter or dot.
    // The negative lookahead [а-яёА-ЯЁa-zA-Z.] prevents matching «см.» (смотри) and
    // run-together words.
    private static let unitRegexes: [(NSRegularExpression, (String, String, String))] = {
        unitForms.compactMap { entry in
            let pat = "(\\d+)\\s*\(NSRegularExpression.escapedPattern(for: entry.pattern))(?![а-яёА-ЯЁa-zA-Z.])"
            guard let re = try? NSRegularExpression(pattern: pat) else { return nil }
            return (re, entry.forms)
        }
    }()

    private static func expandUnits(_ text: String) -> String {
        var result = text as NSString
        // Process each unit pattern independently; iterate regexes in defined order.
        for (re, forms) in unitRegexes {
            let mutable = NSMutableString(string: result)
            let fullRange = NSRange(location: 0, length: mutable.length)
            // Collect all matches first, then replace in reverse order to preserve ranges.
            var matches: [NSTextCheckingResult] = []
            re.enumerateMatches(in: mutable as String, range: fullRange) { m, _, _ in
                if let m { matches.append(m) }
            }
            for match in matches.reversed() {
                let digitsRange = match.range(at: 1)
                let digits = mutable.substring(with: digitsRange)
                // Determine last significant digit for pluralForm.
                let lastDigit = Int(String(digits.last ?? "0")) ?? 0
                let wholePart = Int(digits) ?? 0
                // pluralForm uses the full number for the 11-14 special case.
                let word = pluralForm(wholePart > 0 ? wholePart : lastDigit, forms)
                // Replace entire match with «digits word».
                mutable.replaceCharacters(in: match.range, with: "\(digits) \(word)")
            }
            result = mutable
        }
        return result as String
    }

    // MARK: - Контекстное «г.» → «город» перед топонимом

    // Matches «г.» as a standalone token followed by a word starting with an uppercase
    // Cyrillic letter. The trailing space is consumed so «город Москва» has a single space.
    private static let cityPrefixRegex =
        try? NSRegularExpression(pattern: "\\bг\\.\\s+(?=[А-ЯЁ])")

    private static func expandCityPrefix(_ text: String) -> String {
        guard let re = cityPrefixRegex else { return text }
        let ns = text as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        return re.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "город ")
    }

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

    // MARK: - Склонение числительных по падежу

    enum NumeralCase { case genitive, dative, prepositional }

    // Предлоги → падеж. Список намеренно консервативен: неоднозначные (в, на, с) исключены.
    private static let prepositionCase: [String: NumeralCase] = {
        var d: [String: NumeralCase] = [:]
        for p in ["без", "до", "из", "изо", "от", "ото", "у", "для",
                  "около", "возле", "против", "после", "среди", "кроме", "начиная"] {
            d[p] = .genitive
        }
        for p in ["к", "ко"] { d[p] = .dative }
        for p in ["о", "об", "обо", "при"] { d[p] = .prepositional }
        return d
    }()

    // Единицы 1–9 по трём падежам (индекс 0=род., 1=дат., 2=предл.)
    // 1 склоняется в мужском роде — TODO S5b: учитывать род существительного
    private static let nUnitsCased: [[String]] = [
        [],                                          // 0 — не используется
        ["одного", "одному", "одном"],               // 1
        ["двух",   "двум",   "двух"],                // 2
        ["трёх",   "трём",   "трёх"],                // 3
        ["четырёх","четырём","четырёх"],             // 4
        ["пяти",   "пяти",   "пяти"],               // 5
        ["шести",  "шести",  "шести"],               // 6
        ["семи",   "семи",   "семи"],                // 7
        ["восьми", "восьми", "восьми"],              // 8
        ["девяти", "девяти", "девяти"],              // 9
    ]

    // Тинейджеры 10–19 (единственная форма для всех трёх падежей)
    private static let nTeensCased = [
        "десяти", "одиннадцати", "двенадцати", "тринадцати", "четырнадцати",
        "пятнадцати", "шестнадцати", "семнадцати", "восемнадцати", "девятнадцати",
    ]

    // Десятки 20–90 (единственная форма для всех трёх падежей; индекс = десятки)
    private static let nTensCased = [
        "", "", "двадцати", "тридцати", "сорока",
        "пятидесяти", "шестидесяти", "семидесяти", "восьмидесяти", "девяноста",
    ]

    // Сотни 100–900 по трём падежам
    private static let nHundredsCased: [[String]] = [
        [],                                                   // 0
        ["ста",         "ста",          "ста"],              // 100
        ["двухсот",     "двумстам",     "двухстах"],         // 200
        ["трёхсот",     "трёмстам",     "трёхстах"],         // 300
        ["четырёхсот",  "четырёмстам",  "четырёхстах"],      // 400
        ["пятисот",     "пятистам",     "пятистах"],         // 500
        ["шестисот",    "шестистам",    "шестистах"],         // 600
        ["семисот",     "семистам",     "семистах"],          // 700
        ["восьмисот",   "восьмистам",   "восьмистах"],        // 800
        ["девятисот",   "девятистам",   "девятистах"],        // 900
    ]

    private static func caseIndex(_ c: NumeralCase) -> Int {
        switch c { case .genitive: return 0; case .dative: return 1; case .prepositional: return 2 }
    }

    /// Склоняет число < 1000 в указанном падеже.
    private static func group3WordsCased(_ n: Int, numeralCase: NumeralCase) -> [String] {
        let ci = caseIndex(numeralCase)
        var w: [String] = []
        let h = n / 100
        let rem = n % 100
        let t = rem / 10
        let u = rem % 10
        if h > 0 { w.append(nHundredsCased[h][ci]) }
        if t == 1 {
            w.append(nTeensCased[u])
        } else {
            if t >= 2 { w.append(nTensCased[t]) }
            if u > 0 { w.append(nUnitsCased[u][ci]) }
        }
        return w
    }

    /// Раскрывает целое число в косвенном падеже.
    /// Для чисел ≥ 1000 фолбэк на именительный — TODO S5: тысячи/миллионы в падежах.
    static func integerToWordsCased(_ digits: String, numeralCase: NumeralCase) -> String {
        guard !digits.isEmpty else { return "" }
        guard digits.count <= 9, let value = Int(digits) else {
            return integerToWords(digits)
        }
        if value == 0 { return "ноль" }
        // Числа ≥ 1000: именительный (TODO S5: падежи тысяч/миллионов)
        if value >= 1000 { return integerToWords(digits) }
        return group3WordsCased(value, numeralCase: numeralCase).joined(separator: " ")
    }

    /// Извлекает последнее слово из уже накопленного буфера `out`.
    /// Используется в `expandNumbers` для обнаружения предшествующего предлога.
    private static func lastWord(in s: String) -> String? {
        // Идём с конца, пропускаем пробелы, затем берём буквы.
        var end = s.endIndex
        // Пропустить хвостовые пробелы.
        while end > s.startIndex {
            let prev = s.index(before: end)
            if s[prev].isWhitespace { end = prev } else { break }
        }
        guard end > s.startIndex else { return nil }
        var start = end
        while start > s.startIndex {
            let prev = s.index(before: start)
            if s[prev].isLetter { start = prev } else { break }
        }
        guard start < end else { return nil }
        return String(s[start..<end])
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

            // Определяем падеж по предшествующему предлогу.
            // Только целые однокомпонентные числа раскрываются в косвенном падеже;
            // дроби и проценты оставляем в именительном.
            let governing = lastWord(in: out).map { prepositionCase[$0.lowercased()] } ?? nil

            var tokens: [String] = []
            for (idx, p) in parts.enumerated() {
                if idx > 0 { tokens.append(seps[idx - 1] == "," ? "запятая" : "точка") }
                if let nc = governing, !percent, parts.count == 1 {
                    tokens.append(integerToWordsCased(p, numeralCase: nc))
                } else {
                    tokens.append(numberWords(p))
                }
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
