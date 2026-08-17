import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewer = VoicePreviewer()

    private let pauseOptions: [(String, Double)] = [
        ("Нет", 0), ("0.3 с", 0.3), ("0.5 с", 0.5), ("1 с", 1.0), ("1.5 с", 1.5)
    ]

    private var voiceOptions: [VoiceOption] {
        VoiceCatalog.options(sileroReachable: settings.sileroReachable)
    }

    private var englishVoiceOptions: [VoiceOption] {
        VoiceCatalog.options(sileroReachable: settings.sileroReachable, language: "en")
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Оформление") {
                    Picker("Тема", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .listRowBackground(Theme.surface)
                }

                Section {
                    Picker("Русские книги", selection: $settings.selectedVoice) {
                        ForEach(voiceOptions) { opt in
                            Text(opt.title).tag(opt.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .listRowBackground(Theme.surface)

                    Picker("Английские книги", selection: $settings.selectedVoiceEN) {
                        ForEach(englishVoiceOptions) { opt in
                            Text(opt.title).tag(opt.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .listRowBackground(Theme.surface)
                } header: {
                    Text("Голос")
                } footer: {
                    // Голос выбирается по языку книги автоматически — объясняем это
                    // прямо здесь, иначе два пикера выглядят как «какой из них главный».
                    Text(settings.sileroReachable
                         ? "Голос выбирается по языку книги. Для русских книг доступны улучшенные голоса (нейросеть)."
                         : "Голос выбирается по языку книги. Улучшенные голоса временно недоступны — используется системный голос.")
                }

                Section("Пауза между предложениями") {
                    Picker("Пауза", selection: $settings.pauseBetweenSentences) {
                        ForEach(pauseOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .listRowBackground(Theme.surface)
                }

                Section {
                    HStack {
                        Text("Версия")
                        Spacer()
                        Text("0.1.0").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Min iOS")
                        Spacer()
                        Text("16.0").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("О приложении")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .onAppear { settings.probeSilero() }
            .onChange(of: settings.selectedVoice) { id in
                if let opt = voiceOptions.first(where: { $0.id == id }) {
                    previewer.preview(opt, serverURL: settings.sileroServerURL,
                                      apiKey: settings.sileroAPIKey)
                }
            }
            .onChange(of: settings.selectedVoiceEN) { id in
                if let opt = englishVoiceOptions.first(where: { $0.id == id }) {
                    previewer.preview(opt, serverURL: settings.sileroServerURL,
                                      apiKey: settings.sileroAPIKey)
                }
            }
            .onDisappear { previewer.stop() }
        }
        // Тема задаётся глобально через .appearanceOverride на корне приложения
        // (overrideUserInterfaceStyle окна) — на sheet'ах надёжнее, чем
        // .preferredColorScheme, который застревал при возврате на «Системную».
    }
}
