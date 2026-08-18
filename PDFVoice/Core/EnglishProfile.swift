import Foundation

/// Языковой профиль для английского текста.
///
/// Намеренно ТОНКИЙ по сравнению с `RussianProfile`, и это не недоделка:
/// русское раскрытие существует ради того, чего AVSpeech не умеет — склонения
/// числительных по предлогу («от 2 до 5» → «от двух до пяти»), падежей единиц
/// («5 кг» → «пять килограммов») и ударений для Silero. Английский синтезатор
/// произносит числа, единицы и `Mr./Dr./e.g.` сам и корректно, поэтому
/// переводить их в слова здесь не нужно — попытка «помочь» только испортила бы
/// произношение.
///
/// Остаётся язык-независимая чистка (`TextPipeline`) и детект заголовков.
struct EnglishProfile: LanguageProfile {

    let code = "en"

    // Токенизация — общая реализация из расширения `LanguageProfile`.
    // Проверено: явный `setLanguage(.english)` даёт тот же разбор, что автодетект.

    // MARK: - Детект заголовков

    /// Структура зеркалит `RussianProfile.headingPatterns`: markdown-заголовок,
    /// «Chapter/Part/…» с номером (арабским или римским) и нумерация «1.2 Название».
    private static let headingPatterns: [NSRegularExpression] = [
        "^#{1,3}\\s+\\S",
        "^(chapter|part|section|book|volume|appendix|act|scene)\\s+[0-9ivxlcdm]+",
        "^\\d+(\\.\\d+)+\\s+\\S",
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let specialSectionsStatic: Set<String> = [
        "prologue", "epilogue", "foreword", "afterword", "preface",
        "introduction", "conclusion", "contents", "acknowledgments",
        "acknowledgements", "appendix", "index", "glossary", "notes",
        "dedication", "abstract", "summary",
    ]

    // Вердикт `isHeading` считает общая реализация в `extension LanguageProfile`
    // (см. LanguageProfile.swift) — здесь только языковые таблицы.
    var headingPatterns: [NSRegularExpression] { Self.headingPatterns }
    var specialSections: Set<String> { Self.specialSectionsStatic }

    // MARK: - Раскрытие для озвучки

    /// Только язык-независимое: снять ссылки, схлопнуть многоточия и пробелы.
    /// Числа, единицы и сокращения оставляем синтезатору (см. док-комментарий типа).
    func expandForSpeech(_ sentence: String) -> String {
        TextPipeline.squeezeSpaces(TextPipeline.collapseDots(TextPipeline.stripLinks(sentence)))
    }

    // MARK: - Рендер

    /// Ударения не размечаем: словарь омографов русский, а Silero (единственный
    /// backend, который уважает «+») к английскому не подключается — сервер
    /// держит русскую модель.
    func render(_ raw: String) -> SpokenMarkup {
        SpokenMarkup(text: expandForSpeech(raw), stresses: [])
    }
}
