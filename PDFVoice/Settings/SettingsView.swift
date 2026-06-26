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

    var body: some View {
        NavigationStack {
            List {
                Section("Оформление") {
                    Picker("Тема", selection: $settings.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                }

                Section {
                    Picker("Голос", selection: $settings.selectedVoice) {
                        ForEach(voiceOptions) { opt in
                            Text(opt.title).tag(opt.id)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Голос")
                } footer: {
                    Text(settings.sileroReachable
                         ? "Голоса Silero доступны — сервер подключён."
                         : "Голоса Silero появятся, когда подключится сервер (см. ниже).")
                }

                Section("Пауза между предложениями") {
                    Picker("Пауза", selection: $settings.pauseBetweenSentences) {
                        ForEach(pauseOptions, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    HStack {
                        Text("Адрес сервера")
                        Spacer()
                        TextField("http://localhost:8000", text: $settings.sileroServerURL)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Text("API-ключ")
                        Spacer()
                        SecureField("необязательно", text: $settings.sileroAPIKey)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    HStack {
                        Label(settings.sileroReachable ? "Сервер подключён" : "Сервер недоступен",
                              systemImage: settings.sileroReachable ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(settings.sileroReachable ? .green : .secondary)
                            .font(.subheadline)
                        Spacer()
                        Button("Проверить") { settings.probeSilero() }
                            .font(.subheadline)
                    }
                } header: {
                    Text("Сервер Silero")
                } footer: {
                    Text("Локально: запустите silero-server/start.sh. Удалённо: укажите HTTPS-адрес туннеля и API-ключ из silero-server/.api_key. Голоса Silero появятся в списке выше при успешном подключении.")
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
            }
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
            .onDisappear { previewer.stop() }
        }
        // Применяем тему внутри листа, иначе смена видна только после переоткрытия.
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}
