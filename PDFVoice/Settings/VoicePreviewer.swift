import AVFoundation
import Foundation

/// Проигрывает короткую демо-фразу выбранным голосом в Настройках.
/// Системные голоса — через AVSpeechSynthesizer, Silero — через HTTP-сервер.
/// Самодостаточен: не использует SpeechEngine (тот завязан на очередь предложений).
@MainActor
final class VoicePreviewer: ObservableObject {

    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    /// Озвучивает «Привет, меня зовут {имя}. С радостью могу почитать для тебя».
    func preview(_ option: VoiceOption, serverURL: String, apiKey: String) {
        stop()
        let phrase = "Привет, меня зовут \(option.title). С радостью могу почитать для тебя"
        activateSession()

        switch option.kind {
        case .system:
            let utterance = AVSpeechUtterance(string: phrase)
            if let id = option.systemIdentifier {
                utterance.voice = AVSpeechSynthesisVoice(identifier: id)
            }
            utterance.rate = SpeechEngine.utteranceRate(for: 1.0)
            synth.speak(utterance)

        case .silero:
            guard let speaker = option.sileroSpeaker,
                  !serverURL.isEmpty, let base = URL(string: serverURL) else { return }
            task = Task { [weak self] in
                guard let self else { return }
                guard let data = try? await VoicePreviewer.fetch(base: base, apiKey: apiKey,
                                                                 speaker: speaker, text: phrase),
                      !Task.isCancelled else { return }
                self.player = try? AVAudioPlayer(data: data)
                self.player?.play()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        player?.stop()
        player = nil
    }

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    private struct SileroRequest: Encodable {
        let text: String
        let speaker: String
    }

    private static func fetch(base: URL, apiKey: String,
                              speaker: String, text: String) async throws -> Data {
        var req = URLRequest(url: base.appendingPathComponent("synthesize"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { req.setValue(apiKey, forHTTPHeaderField: "X-API-Key") }
        req.httpBody = try JSONEncoder().encode(SileroRequest(text: text, speaker: speaker))
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }
}
