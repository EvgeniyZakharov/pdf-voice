import Foundation

/// Язык-независимый конвейер очистки текста PDF перед озвучкой.
/// Работает построчно и сохраняет карту смещений UTF-16, чтобы подсветка
/// оставалась привязанной к исходным координатам страницы.
/// Языко-специфичная логика (заголовки, аббревиатуры, числа) живёт в `LanguageProfile`.
enum TextPipeline {

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

    // MARK: - Шаблонный мусор

    /// Строки-шаблоны без полезного для озвучки текста — удаляются на ЛЮБОЙ
    /// позиции (в отличие от колонтитулов, которые ищутся только сверху/снизу).
    // TODO(S-later): рус. паттерны мусора («все права защищены», «стр.», «страница», «из») → RussianProfile
    private static let junkPatterns: [NSRegularExpression] = [
        "©.*\\d{4}",
        "^©",
        "all rights reserved",
        "все права защищены",
        "^\\d{4}-\\d{2}-\\d{2}",
        "^page\\s+\\d+\\s*$",
        "^стр\\.?\\s*\\d+\\s*$",
        "^страница\\s+\\d+\\s*$",
        "^\\d+\\s+of\\s+\\d+\\s*$",
        "^\\d+\\s+из\\s+\\d+\\s*$",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func isJunkLine(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let range = NSRange(t.startIndex..<t.endIndex, in: t)
        return junkPatterns.contains { $0.firstMatch(in: t, range: range) != nil }
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

    /// Оконный детект колонтитулов для длинных документов: бегущие заголовки глав
    /// повторяются в пределах главы, но редко на масштабе всего документа. Делим
    /// страницы на окна и объединяем найденное в каждом окне.
    static func detectBoilerplateWindowed(pages: [[PageLine]], windowSize: Int = 30) -> Set<String> {
        guard pages.count > windowSize else {
            return detectBoilerplate(pages: pages, pageCount: pages.count)
        }
        var result = Set<String>()
        var start = 0
        while start < pages.count {
            let end = min(start + windowSize, pages.count)
            let window = Array(pages[start..<end])
            result.formUnion(detectBoilerplate(pages: window, pageCount: window.count))
            start = end
        }
        return result
    }

    /// Индексы строк страницы, которые надо выбросить.
    static func droppedIndices(lines: [PageLine], boilerplate: Set<String>) -> Set<Int> {
        let n = lines.count
        var dropped: Set<Int> = []
        let regionEnabled = n > 4
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
            if units.isEmpty { return }
            if units.last == space { return }
            units.append(space)
            orig.append(index)
        }

        for (idx, line) in lines.enumerated() where !dropped.contains(idx) {
            let lu = Array(line.text.utf16)
            var end = lu.count
            var joinNext = false
            if end > 0, lu[end - 1] == hyphen {
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
}
