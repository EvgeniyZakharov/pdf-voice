import UIKit

/// Применяет тему оформления к окну приложения через `overrideUserInterfaceStyle`.
///
/// Императивно (UIKit), НЕ через SwiftUI: `PDFVoiceApp` — это `App`, его `body`
/// вычисляется один раз при старте сцены, поэтому повесить реактивность на `.onChange`
/// в модификаторе нельзя (значение `appearance` там застывало). Поэтому вызываем
/// `apply` напрямую из `SettingsStore.appearance.didSet` (живые смены) и один раз из
/// `LibraryView.onAppear` (холодный старт). Действует на всю иерархию, включая sheet'ы —
/// в отличие от `.preferredColorScheme`, который застревал при возврате на «Системную».
enum AppearanceController {
    static func apply(_ appearance: AppAppearance) {
        let style: UIUserInterfaceStyle
        switch appearance {
        case .system: style = .unspecified
        case .light:  style = .light
        case .dark:   style = .dark
        }
        // Окна доступны только на main; didSet может прийти не строго на main-actor.
        DispatchQueue.main.async {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .forEach { $0.overrideUserInterfaceStyle = style }
        }
    }
}
