import AVFoundation
import Foundation
import SwiftUI

/// Режим отображения библиотеки.
enum LibraryLayout: String, CaseIterable, Identifiable {
    case list, grid
    var id: String { rawValue }
    var icon: String { self == .list ? "square.grid.2x2" : "list.bullet" }
}

/// Тема оформления приложения.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "Системная"
        case .light:  return "Светлая"
        case .dark:   return "Тёмная"
        }
    }
    /// nil — следовать системной теме.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

final class SettingsStore: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var pauseBetweenSentences: Double { didSet { ud.set(pauseBetweenSentences, forKey: "pv.pause") } }

    /// Голос для РУССКИХ книг: "sys:<identifier>" (системный) или "silero:<speaker>".
    /// Ключ хранения прежний — миграция не нужна, русский остаётся основным языком.
    @Published var selectedVoice: String  { didSet { ud.set(selectedVoice,   forKey: "pv.selectedVoice") } }

    /// Голос для АНГЛИЙСКИХ книг — всегда системный: сервер Silero держит русскую
    /// модель. Голос выбирается по языку КНИГИ, а не переключается вручную —
    /// см. `ReaderViewModel.applySettings`.
    @Published var selectedVoiceEN: String { didSet { ud.set(selectedVoiceEN, forKey: "pv.selectedVoiceEN") } }

    /// Продакшн-сервер Silero. Зашит в приложение — пользователь его не настраивает,
    /// подключение к улучшенным голосам происходит автоматически.
    let sileroServerURL = "https://tts.pdf-voice.com"
    /// Из Info.plist (`SileroAPIKey`, подставляется из Secrets.xcconfig при сборке —
    /// см. Secrets.xcconfig.example). Пустая строка при отсутствии ключа ведёт к
    /// штатному офлайн-фолбэку на системный голос, а не к крашу.
    let sileroAPIKey = Bundle.main.object(forInfoDictionaryKey: "SileroAPIKey") as? String ?? ""

    @Published var appearance: AppAppearance {
        didSet {
            ud.set(appearance.rawValue, forKey: "pv.appearance")
            AppearanceController.apply(appearance)   // живое применение к окну (sheet'ы тоже)
        }
    }
    /// Тема страницы чтения (reflow). Независима от `appearance`. По умолчанию — сепия.
    @Published var readingTheme: ReadingTheme { didSet { ud.set(readingTheme.rawValue, forKey: "pv.readingTheme") } }
    /// Размер шрифта текста reflow-форматов (pt). Применяется на лету. PDF не трогает.
    @Published var readingFontSize: Double { didSet { ud.set(readingFontSize, forKey: "pv.readingFontSize") } }
    /// Границы регулировки размера шрифта reflow.
    static let fontSizeRange: ClosedRange<Double> = 14...30
    @Published var libraryLayout: LibraryLayout { didSet { ud.set(libraryLayout.rawValue, forKey: "pv.libraryLayout") } }

    /// Доступен ли Silero-сервер (не сохраняется — определяется ping'ом /health).
    @Published var sileroReachable: Bool = false

    init() {
        pauseBetweenSentences = ud.object(forKey: "pv.pause") as? Double ?? 0.3
        // sanitized: выбор, сохранённый до сокращения списка голосов (kseniya,
        // aidar, baya, системные кроме Милены), заменяется голосом по умолчанию.
        selectedVoice         = VoiceCatalog.sanitized(ud.string(forKey: "pv.selectedVoice")
                                                       ?? VoiceCatalog.defaultSelection(),
                                                       for: "ru")
        selectedVoiceEN       = VoiceCatalog.sanitized(ud.string(forKey: "pv.selectedVoiceEN")
                                                       ?? VoiceCatalog.defaultSelection(for: "en"),
                                                       for: "en")
        appearance            = AppAppearance(rawValue: ud.string(forKey: "pv.appearance") ?? "") ?? .system
        readingTheme          = ReadingTheme(rawValue: ud.string(forKey: "pv.readingTheme") ?? "") ?? .sepia
        readingFontSize       = ud.object(forKey: "pv.readingFontSize") as? Double ?? 19
        libraryLayout         = LibraryLayout(rawValue: ud.string(forKey: "pv.libraryLayout") ?? "") ?? .list

        // Чистим старые сохранённые адрес/ключ — раньше настраивались вручную,
        // теперь сервер вшит в приложение.
        ud.removeObject(forKey: "pv.sileroURL")
        ud.removeObject(forKey: "pv.sileroAPIKey")
    }

    /// Пингует Silero-сервер и обновляет `sileroReachable`.
    func probeSilero() {
        let urlStr = sileroServerURL
        let key = sileroAPIKey
        guard !urlStr.isEmpty, let base = URL(string: urlStr) else {
            sileroReachable = false
            return
        }
        Task { @MainActor in
            var req = URLRequest(url: base.appendingPathComponent("health"))
            req.timeoutInterval = 4
            if !key.isEmpty { req.setValue(key, forHTTPHeaderField: "X-API-Key") }
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                sileroReachable = (resp as? HTTPURLResponse)?.statusCode == 200
            } catch {
                sileroReachable = false
            }
        }
    }
}
