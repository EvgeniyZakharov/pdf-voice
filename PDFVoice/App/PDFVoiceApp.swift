import SwiftUI

@main
struct PDFVoiceApp: App {
    @StateObject private var store: DocumentStore
    @StateObject private var settings: SettingsStore
    @StateObject private var coordinator: PlaybackCoordinator

    init() {
        let store = DocumentStore()
        let settings = SettingsStore()
        _store = StateObject(wrappedValue: store)
        _settings = StateObject(wrappedValue: settings)
        _coordinator = StateObject(wrappedValue: PlaybackCoordinator(store: store, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(coordinator)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}
