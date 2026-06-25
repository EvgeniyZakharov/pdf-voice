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

    init(rawText: String, pageIndex: Int, range: NSRange? = nil, boxes: [CGRect] = [],
         isHeading: Bool = false, language: String = "ru") {
        self.rawText = rawText
        self.pageIndex = pageIndex
        self.range = range
        self.boxes = boxes
        self.isHeading = isHeading
        self.language = language
    }
}

/// Извлечение текстового слоя PDF и разбиение на предложения.
/// OCR для сканов появится в M3; здесь — только текстовый слой (PDFKit).
enum PDFTextExtractor {

    private static let profile: any LanguageProfile = RussianProfile()

    /// Разбивает документ на предложения постранично.
    ///
    /// Конвейер: исходный текст страницы → строки → выброс колонтитулов/номеров
    /// (`TextPipeline`) → склейка в чистый текст с картой смещений → токенизация
    /// предложений (`RussianProfile.sentenceRanges`) → раскрытие аббревиатур для озвучки.
    /// Диапазон каждого предложения маппится обратно в координаты исходной строки,
    /// чтобы `PDFPage.selection(for:)` корректно подсвечивал многострочные фрагменты.
    static func sentences(from document: PDFDocument) -> [Sentence] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        // 1. Строки всех страниц (для кросс-страничного детекта колонтитулов).
        var allLines: [[TextPipeline.PageLine]] = []
        allLines.reserveCapacity(pageCount)
        for pi in 0..<pageCount {
            let raw = document.page(at: pi)?.string ?? ""
            allLines.append(TextPipeline.lines(of: raw))
        }
        let boilerplate = TextPipeline.detectBoilerplate(pages: allLines, pageCount: pageCount)

        // 2. Чистка + токенизация постранично.
        var result: [Sentence] = []

        for pi in 0..<pageCount {
            let lines = allLines[pi]
            guard !lines.isEmpty else { continue }

            let dropped = TextPipeline.droppedIndices(lines: lines, boilerplate: boilerplate)
            let (cleaned, origIndex) = TextPipeline.cleanPage(lines, dropped: dropped)
            guard !cleaned.isEmpty else { continue }

            let cleanedUnits = Array(cleaned.utf16)
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

                let nsRange = NSRange(location: origIndex[lo], length: origIndex[hi] - origIndex[lo] + 1)
                result.append(Sentence(rawText: rawSpoken, pageIndex: pi, range: nsRange, isHeading: heading))
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
                                                    isHeading: last.isHeading)
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

    static func pageLines(_ document: PDFDocument) -> [[TextPipeline.PageLine]] {
        let pageCount = document.pageCount
        var allLines: [[TextPipeline.PageLine]] = []
        allLines.reserveCapacity(pageCount)
        for pi in 0..<pageCount {
            let raw = document.page(at: pi)?.string ?? ""
            allLines.append(TextPipeline.lines(of: raw))
        }
        return allLines
    }

    static func extractSentences(pageRange: Range<Int>,
                                  allLines: [[TextPipeline.PageLine]],
                                  boilerplate: Set<String>,
                                  pageOffset: Int = 0) -> [Sentence] {
        var result: [Sentence] = []

        for pi in pageRange {
            guard pi < allLines.count else { continue }
            let lines = allLines[pi]
            guard !lines.isEmpty else { continue }

            let dropped = TextPipeline.droppedIndices(lines: lines, boilerplate: boilerplate)
            let (cleaned, origIndex) = TextPipeline.cleanPage(lines, dropped: dropped)
            guard !cleaned.isEmpty else { continue }

            let cleanedUnits = Array(cleaned.utf16)
            for range in profile.sentenceRanges(in: cleaned) {
                let ns = NSRange(range, in: cleaned)
                guard ns.length > 0 else { continue }
                var lo = ns.location
                var hi = ns.location + ns.length - 1
                while lo <= hi, cleanedUnits[lo] == 0x20 { lo += 1 }
                while hi >= lo, cleanedUnits[hi] == 0x20 { hi -= 1 }
                guard lo <= hi else { continue }
                let rawSpoken = String(utf16CodeUnits: Array(cleanedUnits[lo...hi]), count: hi - lo + 1)
                guard !rawSpoken.isEmpty else { continue }
                let heading = profile.isHeading(rawSpoken)
                let nsRange = NSRange(location: origIndex[lo], length: origIndex[hi] - origIndex[lo] + 1)
                result.append(Sentence(rawText: rawSpoken, pageIndex: pi + pageOffset, range: nsRange, isHeading: heading))
            }
        }
        return mergeCrossPage(result)
    }

    /// Пригоден ли текстовый слой для озвучки.
    ///
    /// Недостаточно проверить «есть ли символы»: у части PDF шрифт без корректной
    /// кодировки (нет ToUnicode CMap), и PDFKit извлекает только цифры/пунктуацию/
    /// латиницу, теряя кириллицу — получается мусор вроде «88.8 159.7 ( HERSON )».
    /// Поэтому требуем достаточную ПЛОТНОСТЬ БУКВ. Если её нет — документ уходит в OCR
    /// (битый файл: ~1% букв; нормальный: ~95%).
    static func hasTextLayer(_ document: PDFDocument) -> Bool {
        var letters = 0
        var nonSpace = 0
        for i in 0..<min(document.pageCount, 5) {
            guard let s = document.page(at: i)?.string else { continue }
            for ch in s where !ch.isWhitespace {
                nonSpace += 1
                if ch.isLetter { letters += 1 }
            }
        }
        guard nonSpace >= 40 else { return false }
        let ratio = Double(letters) / Double(nonSpace)
        return ratio >= 0.35
    }
}
