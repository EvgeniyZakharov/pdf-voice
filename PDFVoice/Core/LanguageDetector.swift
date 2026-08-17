import Foundation
import NaturalLanguage

/// Определение языка книги по образцу её текста.
///
/// Двухступенчато и намеренно консервативно:
/// 1. **Алфавит.** Русский и английский живут в разных алфавитах, поэтому
///    подсчёт кириллических и латинских букв решает вопрос точнее и на порядок
///    дешевле любого статистического детектора.
/// 2. **`NLLanguageRecognizer`** — когда алфавит не даёт перевеса (смешанный
///    текст, много цифр/пунктуации). Обязательно с `languageConstraints`:
///    без них кириллица регулярно опознаётся как украинский/болгарский/сербский,
///    а латиница — как немецкий/голландский, и мы получили бы код языка, для
///    которого у нас нет ни профиля, ни голоса.
///
/// Возвращает `nil`, если уверенности нет (или текста слишком мало) — вызывающий
/// оставляет язык неопределённым и читает книгу языком по умолчанию. Молчаливая
/// ошибка детекта дороже отсутствия ответа: она запишется в библиотеку.
enum LanguageDetector {

    /// Языки, между которыми различаем. Расширяется вместе с набором профилей.
    static let supported: [NLLanguage] = [.russian, .english]

    /// Минимум букв в образце. На двух словах любой детектор гадает.
    private static let minLetters = 120
    /// Перевес алфавита, при котором ответ очевиден без статистики.
    private static let scriptDominance = 0.85
    /// Порог уверенности `NLLanguageRecognizer`.
    private static let minConfidence = 0.65

    static func detect(sample: String) -> String? {
        var cyrillic = 0
        var latin = 0
        for scalar in sample.unicodeScalars {
            switch scalar.value {
            case 0x0410...0x044F, 0x0401, 0x0451: cyrillic += 1
            case 0x41...0x5A, 0x61...0x7A:        latin += 1
            default: break
            }
        }
        let letters = cyrillic + latin
        guard letters >= minLetters else { return nil }

        let cyrillicShare = Double(cyrillic) / Double(letters)
        if cyrillicShare >= scriptDominance { return "ru" }
        if 1 - cyrillicShare >= scriptDominance { return "en" }

        // Алфавиты перемешаны — спрашиваем статистику, ограничив кандидатов.
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = supported
        recognizer.processString(sample)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1)
            .max(by: { $0.value < $1.value }),
              confidence >= minConfidence else { return nil }
        switch language {
        case .russian: return "ru"
        case .english: return "en"
        default:       return nil
        }
    }
}
