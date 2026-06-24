import AVFoundation

/// Единый список голосов для выбора: системные (всегда) + Silero (если сервер
/// доступен). Идентификатор хранится строкой: "sys:<id>" или "silero:<speaker>".
enum VoiceKind { case system, silero }

struct VoiceOption: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: VoiceKind
    let systemIdentifier: String?
    let sileroSpeaker: String?
}

enum VoiceCatalog {

    /// Голоса Silero (показываются только при доступном сервере).
    static let sileroSpeakers: [(id: String, title: String)] = [
        ("kseniya", "Ксения"),
        ("xenia",   "Ксения 2"),
        ("aidar",   "Айдар"),
        ("baya",    "Байя"),
        ("eugene",  "Евгений"),
    ]

    /// Системные русские голоса, лучшие (Enhanced/Premium) сверху. Milena — обычно первый.
    static func systemVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
    }

    /// Голос по умолчанию (Milena, если доступна).
    static func defaultSelection() -> String {
        if let v = systemVoices().first { return "sys:" + v.identifier }
        return "sys:"
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium:  return "Premium"
        case .enhanced: return "Enhanced"
        default:        return "Стандартный"
        }
    }

    static func systemOptions() -> [VoiceOption] {
        systemVoices().map { v in
            VoiceOption(id: "sys:" + v.identifier,
                        title: v.name,
                        subtitle: qualityLabel(v),
                        kind: .system,
                        systemIdentifier: v.identifier,
                        sileroSpeaker: nil)
        }
    }

    static func sileroOptions() -> [VoiceOption] {
        sileroSpeakers.map { s in
            VoiceOption(id: "silero:" + s.id,
                        title: s.title,
                        subtitle: "Silero · нейросеть",
                        kind: .silero,
                        systemIdentifier: nil,
                        sileroSpeaker: s.id)
        }
    }

    /// Полный список для выбора.
    static func options(sileroReachable: Bool) -> [VoiceOption] {
        systemOptions() + (sileroReachable ? sileroOptions() : [])
    }
}
