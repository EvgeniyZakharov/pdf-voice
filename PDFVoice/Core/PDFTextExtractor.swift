import Foundation
import NaturalLanguage
import PDFKit

/// Одно предложение для озвучки + привязка к месту в PDF (для подсветки и авто-прокрутки).
struct Sentence: Identifiable {
    let id = UUID()
    /// Очищенный «сырой» текст — без раскрытия аббревиатур/чисел.
    /// `RussianProfile.expandForSpeech` применяется при постановке в очередь синтезатора,
    /// поэтому кэш хранит оригинал и улучшения лингвистики не инвалидируют его.
    let rawText: String
    let pageIndex: Int
    /// Диапазон в исходной строке страницы (`PDFPage.string`) — для текстового слоя,
    /// подсветка через `page.selection(for:)`. nil для OCR-страниц.
    let range: NSRange?
    /// Боксы строк в координатах страницы — для OCR-страниц (подсветка аннотациями).
    let boxes: [CGRect]
    /// Похоже ли предложение на заголовок главы/раздела. Вычисляется из `rawText`
    /// ДО раскрытия чисел словами, иначе детект «Глава 5» перестал бы срабатывать.
    let isHeading: Bool
    /// Язык предложения — передаётся в кэш для возможного использования синтезатором.
    let language: String
    /// Reflow-локатор: смещение начала предложения (UTF-16) в тексте главы/секции.
    /// Используется ReflowRenderer (TextKit) вместо PDF-привязок `range`/`boxes`.
    /// Для PDF-форматов остаётся nil; для reflow `pageIndex` несёт индекс главы.
    let charOffset: Int?

    init(rawText: String, pageIndex: Int, range: NSRange? = nil, boxes: [CGRect] = [],
         isHeading: Bool = false, language: String = "ru", charOffset: Int? = nil) {
        self.rawText = rawText
        self.pageIndex = pageIndex
        self.range = range
        self.boxes = boxes
        self.isHeading = isHeading
        self.language = language
        self.charOffset = charOffset
    }
}

/// Одно предложение, ещё не привязанное к странице/боксам: результат общего
/// шага «токенизация чистого текста → обрезка пробелов по краям → детект
/// заголовка → перевод диапазона в исходные UTF-16-координаты через `origIndex`».
/// Используется тремя местами нарезки (`PDFTextExtractor.sentences`,
/// `PDFTextExtractor.extractSentences`, `OCRTextExtractor.sentences`) — раньше
/// каждое дублировало этот цикл почти дословно.
struct TokenizedSentence {
    let rawText: String
    let isHeading: Bool
    /// Первый и последний (включительно) UTF-16 код-юнит предложения в ИСХОДНОЙ
    /// строке страницы (`origIndex`, не в `cleaned`).
    let oLo: Int
    let oHi: Int
}

/// Извлечение текстового слоя PDF и разбиение на предложения.
/// OCR для сканов появится в M3; здесь — только текстовый слой (PDFKit).
enum PDFTextExtractor {

    /// Общий шаг нарезки: токенизирует уже очищенную страницу (`cleanPage`) на
    /// предложения через `profile.sentenceRanges`, обрезает пробелы по краям и
    /// мапит диапазон обратно в координаты исходной строки страницы через
    /// `origIndex`. Не знает про `Sentence`/боксы/страницы — это дело вызывающих.
    static func tokenize(cleaned: String, origIndex: [Int],
                         profile: any LanguageProfile) -> [TokenizedSentence] {
        guard !cleaned.isEmpty else { return [] }
        let cleanedUnits = Array(cleaned.utf16)
        var result: [TokenizedSentence] = []
        for range in profile.sentenceRanges(in: cleaned) {
            let ns = NSRange(range, in: cleaned)
            guard ns.length > 0 else { continue }

            // Обрезаем пробелы по краям токена (в координатах чистого текста).
            var lo = ns.location
            var hi = ns.location + ns.length - 1
            while lo <= hi, cleanedUnits[lo] == 0x20 { lo += 1 }
            while hi >= lo, cleanedUnits[hi] == 0x20 { hi -= 1 }
            guard lo <= hi else { continue }

            let rawSpoken = String(utf16CodeUnits: Array(cleanedUnits[lo...hi]), count: hi - lo + 1)
            guard !rawSpoken.isEmpty else { continue }
            let heading = profile.isHeading(rawSpoken)
            result.append(TokenizedSentence(rawText: rawSpoken, isHeading: heading,
                                            oLo: origIndex[lo], oHi: origIndex[hi]))
        }
        return result
    }

    /// Разбивает документ на предложения постранично.
    ///
    /// Конвейер: исходный текст страницы → строки → выброс колонтитулов/номеров
    /// (`TextPipeline`) → склейка в чистый текст с картой смещений → токенизация
    /// предложений (`LanguageProfile.sentenceRanges`) → раскрытие аббревиатур для озвучки.
    /// Диапазон каждого предложения маппится обратно в координаты исходной строки,
    /// чтобы `PDFPage.selection(for:)` корректно подсвечивал многострочные фрагменты.
    ///
    /// `profile` — языковой профиль книги; по умолчанию русский, поэтому вызов
    /// без него ведёт себя как раньше.
    static func sentences(from document: PDFDocument,
                          profile: any LanguageProfile = LanguageProfiles.default) -> [Sentence] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        // 1. Строки всех страниц (для кросс-страничного детекта колонтитулов).
        var allLines: [[TextPipeline.PageLine]] = []
        allLines.reserveCapacity(pageCount)
        for pi in 0..<pageCount {
            let raw = document.page(at: pi)?.string ?? ""
            allLines.append(TextPipeline.lines(of: raw))
        }
        // Оконный детект (T5): для документов ≤ windowSize страниц ведёт себя как
        // раньше (сам падает на плоский `detectBoilerplate` внутри), но приводит
        // этот путь к тому же вызову, что и прогрессивную/OCR/mixed-загрузку —
        // единая точка правды вместо трёх разных порогов на трёх разных путях.
        let boilerplate = TextPipeline.detectBoilerplateWindowed(pages: allLines)

        // 2. Чистка + токенизация постранично.
        var result: [Sentence] = []

        for pi in 0..<pageCount {
            let lines = allLines[pi]
            guard !lines.isEmpty else { continue }

            let dropped = TextPipeline.droppedIndices(lines: lines, boilerplate: boilerplate)
            let (cleaned, origIndex) = TextPipeline.cleanPage(lines, dropped: dropped)
            guard !cleaned.isEmpty else { continue }

            for tok in tokenize(cleaned: cleaned, origIndex: origIndex, profile: profile) {
                let nsRange = NSRange(location: tok.oLo, length: tok.oHi - tok.oLo + 1)
                result.append(Sentence(rawText: tok.rawText, pageIndex: pi, range: nsRange,
                                       isHeading: tok.isHeading, language: profile.code))
            }
        }
        return mergeCrossPage(result)
    }

    /// Склеивает предложение, разрезанное границей страницы.
    ///
    /// Токенизация идёт постранично, поэтому фраза, перетекающая на следующую
    /// страницу, попадает в два `Sentence` — и между ними слышна лишняя пауза.
    /// Признак разрыва: предыдущий фрагмент не оканчивается завершающей
    /// пунктуацией, а следующий (на другой странице) начинается со строчной
    /// буквы (продолжение, а не новый заголовок/абзац). Текст объединяем для
    /// озвучки; подсветку оставляем на первом фрагменте.
    static func mergeCrossPage(_ sentences: [Sentence]) -> [Sentence] {
        guard sentences.count > 1 else { return sentences }
        var result: [Sentence] = []
        result.reserveCapacity(sentences.count)
        for s in sentences {
            if let last = result.last,
               last.pageIndex != s.pageIndex,
               !last.isHeading, !s.isHeading,
               !endsWithTerminator(last.rawText),
               startsLowercased(s.rawText) {
                result[result.count - 1] = Sentence(rawText: last.rawText + " " + s.rawText,
                                                    pageIndex: last.pageIndex,
                                                    range: last.range,
                                                    boxes: last.boxes,
                                                    isHeading: last.isHeading,
                                                    language: last.language,
                                                    charOffset: last.charOffset)
            } else {
                result.append(s)
            }
        }
        return result
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…", ":", ";"]

    private static func endsWithTerminator(_ text: String) -> Bool {
        guard let last = text.reversed().first(where: { !$0.isWhitespace }) else { return true }
        return terminators.contains(last)
    }

    private static func startsLowercased(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first.isLowercase
    }

    static func extractSentences(pageRange: Range<Int>,
                                  allLines: [[TextPipeline.PageLine]],
                                  boilerplate: Set<String>,
                                  pageOffset: Int = 0,
                                  profile: any LanguageProfile = LanguageProfiles.default) -> [Sentence] {
        var result: [Sentence] = []

        for pi in pageRange {
            guard pi < allLines.count else { continue }
            let lines = allLines[pi]
            guard !lines.isEmpty else { continue }

            let dropped = TextPipeline.droppedIndices(lines: lines, boilerplate: boilerplate)
            let (cleaned, origIndex) = TextPipeline.cleanPage(lines, dropped: dropped)
            guard !cleaned.isEmpty else { continue }

            for tok in tokenize(cleaned: cleaned, origIndex: origIndex, profile: profile) {
                let nsRange = NSRange(location: tok.oLo, length: tok.oHi - tok.oLo + 1)
                result.append(Sentence(rawText: tok.rawText, pageIndex: pi + pageOffset, range: nsRange,
                                       isHeading: tok.isHeading, language: profile.code))
            }
        }
        return mergeCrossPage(result)
    }

}
