import Foundation
import NaturalLanguage

/// Сменный языковой профиль, инкапсулирующий токенизацию и речевое раскрытие
/// для конкретного языка. Язык-независимый pipeline живёт в `TextPipeline`.
///
/// `Sendable`: профили не имеют изменяемого состояния (только статические
/// таблицы), а экстракторы получают их внутрь `Task.detached`.
protocol LanguageProfile: Sendable {
    /// BCP-47 код языка, например «ru» или «en».
    var code: String { get }

    /// Разбивает очищенный текст страницы на диапазоны предложений.
    /// Реализация должна точно повторять поведение `NLTokenizer(.sentence)
    /// .enumerateTokens` — чтобы golden-тест на идентичность вывода проходил.
    func sentenceRanges(in cleaned: String) -> [Range<String.Index>]

    /// Является ли строка заголовком главы/раздела.
    func isHeading(_ raw: String) -> Bool

    /// Раскрывает аббревиатуры, числа, маркеры списков и убирает ссылки
    /// непосредственно перед постановкой предложения в очередь синтезатора.
    /// Не влияет на диапазон подсветки.
    func expandForSpeech(_ sentence: String) -> String

    /// Раскрывает текст через `expandForSpeech`, затем вычисляет UTF-16 смещения
    /// ударных гласных для слов из словаря ударений.
    /// AVSpeech-backend использует только `text`; Silero-backend вставляет «+» по `stresses`.
    func render(_ raw: String) -> SpokenMarkup
}

extension LanguageProfile {

    /// Разбиение на предложения общее для всех профилей: `NLTokenizer(.sentence)`
    /// сам определяет язык строки. Проверено эмпирически — явный
    /// `setLanguage(.english)` на английских предложениях (включая «Mr. Smith»,
    /// «5 p.m.», «$5.50 in the U.S.») даёт РОВНО тот же разбор, что автодетект,
    /// поэтому отдельная английская реализация ничего не добавила бы.
    ///
    /// Профиль может переопределить метод, если его языку понадобится своё
    /// правило (русская реализация раньше была здесь же, побайтно эта).
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
}

/// Реестр профилей: ЕДИНСТВЕННОЕ место, где код языка превращается в реализацию.
/// Экстракторы и `SpeechEngine` больше не знают о конкретных профилях — они
/// принимают `any LanguageProfile` параметром, а собирает их вызывающий
/// (`ReaderViewModel` по языку книги).
enum LanguageProfiles {

    /// Приоритетный язык приложения — русский (см. CLAUDE.md).
    static let defaultCode = "ru"

    /// Профиль по умолчанию: значение default-параметров у экстракторов, то есть
    /// поведение вызова без указания языка остаётся прежним, русским.
    static var `default`: any LanguageProfile { profile(for: defaultCode) }

    /// Профиль по BCP-47 коду («ru», «ru-RU», «en_US»). Неизвестный код —
    /// русский профиль: чтение не должно ломаться из-за неудачного детекта.
    static func profile(for code: String) -> any LanguageProfile {
        switch primarySubtag(code) {
        case "en": return EnglishProfile()
        case "ru": return RussianProfile()
        default:   return RussianProfile()
        }
    }

    /// «ru-RU» / «ru_RU» → «ru».
    private static func primarySubtag(_ code: String) -> String {
        String(code.lowercased().prefix { $0 != "-" && $0 != "_" })
    }
}
