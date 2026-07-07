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

    /// Фон «бумаги» reflow-страницы. Палитра aurora: светлая — тёплый крем,
    /// сепия — пергамент, тёмная — графит с фиолетовым отливом (не бурый).
    var pageBackgroundUI: UIColor {
        switch self {
        case .light: return UIColor(red: 250.0/255, green: 246.0/255, blue: 239.0/255, alpha: 1)
        case .sepia: return UIColor(red: 244.0/255, green: 236.0/255, blue: 220.0/255, alpha: 1)
        case .dark:  return UIColor(red:  22.0/255, green:  19.0/255, blue:  27.0/255, alpha: 1)
        }
    }

    /// Цвет основного текста. Фиксирован под фон темы (не адаптивный `.label`).
    var pageTextUI: UIColor {
        switch self {
        case .light: return UIColor(red:  42.0/255, green:  37.0/255, blue:  33.0/255, alpha: 1)
        case .sepia: return UIColor(red:  59.0/255, green:  49.0/255, blue:  40.0/255, alpha: 1)
        case .dark:  return UIColor(red: 220.0/255, green: 215.0/255, blue: 206.0/255, alpha: 1)
        }
    }

    /// Фон подсветки текущего предложения — спокойный мёд/золото под фон темы
    /// (не системный жёлтый: он кричит и выбивается из тёплой палитры).
    var highlightUI: UIColor {
        switch self {
        case .light: return UIColor(red: 228.0/255, green: 197.0/255, blue: 124.0/255, alpha: 0.38)
        case .sepia: return UIColor(red: 221.0/255, green: 185.0/255, blue: 117.0/255, alpha: 0.42)
        case .dark:  return UIColor(red: 150.0/255, green: 120.0/255, blue:  60.0/255, alpha: 0.55)
        }
    }

    /// Подсветка предложения, ВЫБРАННОГО тапом (кандидат на запуск) — тот же тон,
    /// но бледнее активной `highlightUI`, чтобы отличать «что выбрано» от «что
    /// читается сейчас».
    var pendingHighlightUI: UIColor {
        switch self {
        case .light: return UIColor(red: 228.0/255, green: 197.0/255, blue: 124.0/255, alpha: 0.18)
        case .sepia: return UIColor(red: 221.0/255, green: 185.0/255, blue: 117.0/255, alpha: 0.20)
        case .dark:  return UIColor(red: 150.0/255, green: 120.0/255, blue:  60.0/255, alpha: 0.28)
        }
    }
}
