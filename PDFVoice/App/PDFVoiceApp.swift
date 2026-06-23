import SwiftUI

@main
struct PDFVoiceApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(settings)
        }
    }
}
