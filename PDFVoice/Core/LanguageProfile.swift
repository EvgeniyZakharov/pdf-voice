import Foundation

/// Сменный языковой профиль, инкапсулирующий токенизацию и речевое раскрытие
/// для конкретного языка. Язык-независимый pipeline живёт в `TextPipeline`.
protocol LanguageProfile {
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
