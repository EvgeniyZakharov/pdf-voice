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

    /// Выбранный голос: "sys:<identifier>" (системный) или "silero:<speaker>".
    @Published var selectedVoice: String  { didSet { ud.set(selectedVoice,   forKey: "pv.selectedVoice") } }
    @Published var sileroServerURL: String { didSet { ud.set(sileroServerURL, forKey: "pv.sileroURL")     } }
    @Published var sileroAPIKey: String   { didSet { ud.set(sileroAPIKey,    forKey: "pv.sileroAPIKey")  } }

    @Published var appearance: AppAppearance { didSet { ud.set(appearance.rawValue, forKey: "pv.appearance") } }
    @Published var libraryLayout: LibraryLayout { didSet { ud.set(libraryLayout.rawValue, forKey: "pv.libraryLayout") } }

    /// Доступен ли Silero-сервер (не сохраняется — определяется ping'ом /health).
    @Published var sileroReachable: Bool = false

    init() {
        pauseBetweenSentences = ud.object(forKey: "pv.pause") as? Double ?? 0.3
        selectedVoice         = ud.string(forKey: "pv.selectedVoice") ?? VoiceCatalog.defaultSelection()
        sileroServerURL       = ud.string(forKey: "pv.sileroURL")     ?? "https://elementary-comm-bundle-chester.trycloudflare.com"
        sileroAPIKey          = ud.string(forKey: "pv.sileroAPIKey")  ?? "fTf4NSY-CgBp6EueBT0yyEDKa6VtUO_v"
        appearance            = AppAppearance(rawValue: ud.string(forKey: "pv.appearance") ?? "") ?? .system
        libraryLayout         = LibraryLayout(rawValue: ud.string(forKey: "pv.libraryLayout") ?? "") ?? .list
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
