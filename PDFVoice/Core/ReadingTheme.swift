import SwiftUI
import UIKit

/// Тема страницы чтения (фон + текст + подсветка). Независима от `AppAppearance`
/// (та задаёт оформление хрома): ночью можно хотеть тёмную страницу при светлом UI —
/// как в Apple Books/Kindle. Применяется ТОЛЬКО к reflow-форматам (TXT/FB2/EPUB/DOCX);
/// PDF всегда на кремовой бумаге (честная инверсия скана/иллюстраций выглядит плохо).
enum ReadingTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: return "Светлая"
        case .sepia: return "Сепия"
        case .dark:  return "Тёмная"
        }
    }

    /// Фон «бумаги» reflow-страницы.
    var pageBackgroundUI: UIColor {
        switch self {
        case .light: return UIColor(red: 250.0/255, green: 249.0/255, blue: 247.0/255, alpha: 1)
        case .sepia: return UIColor(red: 244.0/255, green: 236.0/255, blue: 220.0/255, alpha: 1)
        case .dark:  return UIColor(red:  30.0/255, green:  27.0/255, blue:  24.0/255, alpha: 1)
        }
    }

    /// Цвет основного текста. Фиксирован под фон темы (не адаптивный `.label`).
    var pageTextUI: UIColor {
        switch self {
        case .light: return UIColor(red:  26.0/255, green:  26.0/255, blue:  26.0/255, alpha: 1)
        case .sepia: return UIColor(red:  44.0/255, green:  38.0/255, blue:  32.0/255, alpha: 1)
        case .dark:  return UIColor(red: 232.0/255, green: 224.0/255, blue: 212.0/255, alpha: 1)
        }
    }

    /// Фон подсветки текущего предложения — контраст под фон темы. На светлых —
    /// жёлтый; на тёмной — тёплый золотистый (жёлтый по тёмному читается слабо).
    var highlightUI: UIColor {
        switch self {
        case .light, .sepia: return UIColor.systemYellow.withAlphaComponent(0.40)
        case .dark:          return UIColor(red: 140.0/255, green: 110.0/255, blue: 40.0/255, alpha: 0.60)
        }
    }
}
