import Foundation

/// Глава reflow-книги: заголовок (для оглавления) + полный текст.
/// Текст хранится ВЕРБАТИМ — `charOffset` предложений указывает в него,
/// и подсветка в TextKit совпадает байт-в-байт.
struct BookChapter {
    let title: String?
    let text: String
}

/// Логическая модель reflow-книги (TXT/FB2/EPUB/DOCX) — независимая от вёрстки.
/// PDF не использует эту модель (у него `PDFDocument` + постраничные `Sentence`).
struct BookContent {
    let chapters: [BookChapter]

    var isEmpty: Bool { chapters.allSatisfy { $0.text.isEmpty } }

    /// Плоский текст для рендера TextKit + глобальные UTF-16 смещения начала каждой
    /// главы. Единственный авторитет склейки: и рендерер, и маппинг подсветки
    /// (`chapterOffsets[pageIndex] + charOffset`) обязаны использовать ЭТОТ результат.
    func flatten(separator: String = "\n\n") -> (text: String, chapterOffsets: [Int]) {
        var offsets: [Int] = []
        offsets.reserveCapacity(chapters.count)
        var cursor = 0
        let sepLen = (separator as NSString).length
        for (i, ch) in chapters.enumerated() {
            offsets.append(cursor)
            cursor += (ch.text as NSString).length
            if i < chapters.count - 1 { cursor += sepLen }
        }
        return (chapters.map { $0.text }.joined(separator: separator), offsets)
    }
}

/// Парсер конкретного reflow-формата в логическую модель.
/// Реализации: `PlainTextSource` (MF1), далее `FB2Source`/`EPUBSource`/`DOCXSource`.
protocol ReflowSource {
    /// Синхронный разбор файла; вызывается off-main внутри `Task.detached`.
    func parse() throws -> BookContent
}

/// Разбиение reflow-контента на предложения для озвучки.
/// Использует ту же токенизацию `LanguageProfile`, что и PDF-путь (паритет),
/// но БЕЗ PDF-механики колонтитулов/номеров страниц — в reflow их нет.
enum ReflowExtractor {
    private static let profile: any LanguageProfile = RussianProfile()

    /// Для каждой главы режет текст на предложения. `pageIndex` = индекс главы,
    /// `charOffset` = UTF-16 смещение начала предложения в тексте главы,
    /// `rawText` = ВЕРБАТИМ-срез (для точной подсветки диапазоном в TextKit).
    static func sentences(from content: BookContent) -> [Sentence] {
        var result: [Sentence] = []
        for (chapterIndex, chapter) in content.chapters.enumerated() {
            let ns = chapter.text as NSString
            for range in profile.sentenceRanges(in: chapter.text) {
                let nsRange = NSRange(range, in: chapter.text)
                let raw = ns.substring(with: nsRange)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                result.append(Sentence(
                    rawText: raw,
                    pageIndex: chapterIndex,
                    isHeading: profile.isHeading(trimmed),
                    language: profile.code,
                    charOffset: nsRange.location
                ))
            }
        }
        return result
    }
}
