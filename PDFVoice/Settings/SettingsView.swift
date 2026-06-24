import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private let pauseOptions: [(String, Double)] = [
        ("Нет", 0), ("0.3 с", 0.3), ("0.5 с", 0.5), ("1 с", 1.0), ("1.5 с", 1.5)
    ]

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
                    ForEach(VoiceCatalog.options(sileroReachable: settings.sileroReachable)) { opt in
                        Button {
                            settings.selectedVoice = opt.id
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.title).foregroundStyle(.primary)
                                    Text(opt.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.selectedVoice == opt.id {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Голос")
                } footer: {
                    Text(settings.sileroReachable
                         ? "Голоса Silero доступны — сервер подключён."
                         : "Голоса Silero появятся, когда подключится сервер (см. ниже).")
                }

                Section("Скорость по умолчанию") {
                    ForEach(SpeechEngine.speedOptions, id: \.self) { option in
                        Button {
                            settings.speed = option
                        } label: {
                            HStack {
                                Text(ReaderView.speedLabel(option))
                                    .foregroundStyle(.primary)
                                Spacer()
                                if settings.speed == option {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }

                Section("Пауза между предложениями") {
                    ForEach(pauseOptions, id: \.1) { label, value in
                        Button {
                            settings.pauseBetweenSentences = value
                        } label: {
                            HStack {
                                Text(label).foregroundStyle(.primary)
                                Spacer()
                                if settings.pauseBetweenSentences == value {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
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
        }
        // Применяем тему внутри листа, иначе смена видна только после переоткрытия.
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}
