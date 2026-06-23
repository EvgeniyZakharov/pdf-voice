import AVFoundation
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private let voices = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == "ru-RU" }
        .sorted { $0.quality.rawValue > $1.quality.rawValue }

    private let pauseOptions: [(String, Double)] = [
        ("Нет", 0), ("0.3 с", 0.3), ("0.5 с", 0.5), ("1 с", 1.0), ("1.5 с", 1.5)
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("Голос") {
                    if voices.isEmpty {
                        Text("Русские голоса не найдены")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(voices, id: \.identifier) { v in
                            Button {
                                settings.voiceIdentifier = v.identifier
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(v.name).foregroundStyle(.primary)
                                        Text(qualityLabel(v))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if settings.voiceIdentifier == v.identifier {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                        }
                    }
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
                    Toggle("Silero TTS (нейросеть)", isOn: $settings.useSilero)
                    if settings.useSilero {
                        HStack {
                            Text("Адрес сервера")
                            Spacer()
                            TextField("http://localhost:8000", text: $settings.sileroServerURL)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(.secondary)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        Picker("Голос", selection: $settings.sileroSpeaker) {
                            Text("Ксения").tag("kseniya")
                            Text("Ксения 2").tag("xenia")
                            Text("Айдар").tag("aidar")
                            Text("Байя").tag("baya")
                            Text("Евгений").tag("eugene")
                        }
                    }
                } header: {
                    Text("Нейросетевой голос")
                } footer: {
                    if settings.useSilero {
                        Text("Запустите silero-server/start.sh на Mac перед использованием.")
                    }
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
        }
    }

    private func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Стандартный"
        }
    }
}
