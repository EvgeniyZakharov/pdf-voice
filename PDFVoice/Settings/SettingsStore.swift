import AVFoundation
import Foundation

final class SettingsStore: ObservableObject {
    private let ud = UserDefaults.standard

    @Published var speed: Double             { didSet { ud.set(speed,                    forKey: "pv.speed")  } }
    @Published var voiceIdentifier: String   { didSet { ud.set(voiceIdentifier,          forKey: "pv.voice")  } }
    @Published var pauseBetweenSentences: Double { didSet { ud.set(pauseBetweenSentences, forKey: "pv.pause") } }

    @Published var useSilero: Bool        { didSet { ud.set(useSilero,        forKey: "pv.useSilero")     } }
    @Published var sileroServerURL: String { didSet { ud.set(sileroServerURL, forKey: "pv.sileroURL")     } }
    @Published var sileroSpeaker: String  { didSet { ud.set(sileroSpeaker,   forKey: "pv.sileroSpeaker") } }

    var preferredVoice: AVSpeechSynthesisVoice? {
        voiceIdentifier.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: voiceIdentifier)
    }

    init() {
        speed                 = ud.object(forKey: "pv.speed")  as? Double ?? 1.0
        voiceIdentifier       = ud.string(forKey:  "pv.voice") ?? ""
        pauseBetweenSentences = ud.object(forKey: "pv.pause") as? Double ?? 0.3
        useSilero             = ud.bool(forKey: "pv.useSilero")
        sileroServerURL       = ud.string(forKey: "pv.sileroURL")     ?? "http://localhost:8000"
        sileroSpeaker         = ud.string(forKey: "pv.sileroSpeaker") ?? "xenia"
    }
}
