import SwiftUI
import UIKit

/// Палитра приложения — тёплый монохром в стиле my-aurora.ru.
/// Акцент адаптивен под тему: тёмно-тёплый на светлой, тёпло-белый на тёмной,
/// чтобы иконки/текст оставались контрастными в обеих темах.
enum Theme {
    /// Тёплый тёмный (#2C2620) — `--w-text` / `--w-active-bg` сайта.
    private static let warmDark  = UIColor(red: 44.0/255, green: 38.0/255, blue: 32.0/255, alpha: 1)
    /// Тёплый белый (#FFF8EE) — `--w-active-text` сайта.
    private static let warmLight = UIColor(red: 255.0/255, green: 248.0/255, blue: 238.0/255, alpha: 1)

    /// Акцент: тёмный на светлой теме, светлый на тёмной.
    static let accent = Color(UIColor { $0.userInterfaceStyle == .dark ? warmLight : warmDark })

    /// Контрастный цвет поверх акцента (глиф на кнопке play, текст на пузырьке).
    static let onAccent = Color(UIColor { $0.userInterfaceStyle == .dark ? warmDark : warmLight })

    /// Кремовая «бумага» книги (#F4ECDC — `--w-surface-bg` сайта).
    static let pageBackground = Color(red: 244.0/255, green: 236.0/255, blue: 220.0/255)
    static let pageBackgroundUI = UIColor(red: 244.0/255, green: 236.0/255, blue: 220.0/255, alpha: 1)
}
