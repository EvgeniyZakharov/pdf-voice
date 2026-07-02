import SwiftUI
import UIKit

/// Дизайн-система приложения — спокойный тёплый монохром по мотивам aurora.
/// Тёмная тема: глубокий графит с фиолетовым отливом + тёпло-серебряный акцент
/// (фон сайта #1F1C25→#000, кнопки #B3B2B2→#F5EFEF, рамки rgba(253,248,238,.14)).
/// Светлая тема: тёплый крем (#FBF5EC) + тёмно-кофейный акцент (#2C2620) —
/// палитра aurora `women-light`. Все цвета адаптивны через dynamic provider:
/// тема хрома задаётся `AppearanceController` (overrideUserInterfaceStyle),
/// цвета переключаются сами.
enum Theme {
    // MARK: - Базовые константы палитры

    /// Тёмно-кофейный (#2C2620) — акцент/текст светлой темы.
    private static let coffee     = UIColor(red:  44.0/255, green:  38.0/255, blue:  32.0/255, alpha: 1)
    /// Тёплый крем (#FFF8EE) — контраст поверх кофейного.
    private static let cream      = UIColor(red: 255.0/255, green: 248.0/255, blue: 238.0/255, alpha: 1)
    /// Тёпло-серебряный (#E8E2D6) — акцент тёмной темы (середина градиента кнопок aurora).
    private static let silver     = UIColor(red: 232.0/255, green: 226.0/255, blue: 214.0/255, alpha: 1)
    /// Графит с фиолетовым отливом (#14121A) — фон тёмной темы.
    private static let graphite   = UIColor(red:  20.0/255, green:  18.0/255, blue:  26.0/255, alpha: 1)
    /// Приподнятая поверхность тёмной темы (#1E1B24).
    private static let graphiteUp = UIColor(red:  30.0/255, green:  27.0/255, blue:  36.0/255, alpha: 1)
    /// Кремовый фон светлой темы (#FBF5EC).
    private static let creamBg    = UIColor(red: 251.0/255, green: 245.0/255, blue: 236.0/255, alpha: 1)
    /// Приподнятая поверхность светлой темы (#FFFDF8).
    private static let creamUp    = UIColor(red: 255.0/255, green: 253.0/255, blue: 248.0/255, alpha: 1)

    private static func adaptive(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    // MARK: - Цвета

    /// Акцент: кофейный на светлой теме, тёпло-серебряный на тёмной.
    static let accent = Color(adaptive(dark: silver, light: coffee))

    /// Контрастный цвет поверх акцента (глиф на кнопке play, текст на бейдже).
    static let onAccent = Color(adaptive(dark: graphite, light: cream))

    /// Фон экранов хрома (библиотека, настройки, листы, зона плеера).
    static let background = Color(adaptive(dark: graphite, light: creamBg))

    /// Приподнятая поверхность: строки списков, карточки, подложки баров.
    static let surface = Color(adaptive(dark: graphiteUp, light: creamUp))

    /// Тонкая тёплая рамка (aurora: rgba(253,248,238,.14) / #E7DCCB).
    static let hairline = Color(adaptive(
        dark:  UIColor(red: 253.0/255, green: 248.0/255, blue: 238.0/255, alpha: 0.14),
        light: UIColor(red: 231.0/255, green: 220.0/255, blue: 203.0/255, alpha: 1)))

    /// Спокойная медовая подсветка выделения/предложения в PDF
    /// (вместо кричащего systemYellow; страница PDF всегда кремовая).
    static let pdfHighlightUI = UIColor(red: 217.0/255, green: 179.0/255, blue: 106.0/255, alpha: 0.45)

    // MARK: - Форма

    /// Скругление обложек книг и миниатюр страниц.
    static let radiusCover: CGFloat = 8
    /// Скругление карточек и плавающих баннеров.
    static let radiusCard: CGFloat = 16


    // MARK: - Бумага PDF

    /// Кремовая «бумага» PDF (#F4ECDC). Reflow-страница использует
    /// `ReadingTheme.pageBackgroundUI` (тема чтения); PDF — всегда эту.
    static let pageBackground = Color(red: 244.0/255, green: 236.0/255, blue: 220.0/255)
    static let pageBackgroundUI = UIColor(red: 244.0/255, green: 236.0/255, blue: 220.0/255, alpha: 1)
}
