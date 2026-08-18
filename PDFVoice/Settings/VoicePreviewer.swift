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

    /// Озвучивает «Привет, меня зовут {имя}. С радостью могу почитать для тебя»,
    /// а английским голосом — английскую фразу: русская у него звучала бы
    /// набором нечитаемых звуков (фонетику задаёт голос, а не текст).
    ///
    /// `coordinator` — активная сессия чтения (если есть) ставится на паузу
    /// ПЕРЕД превью: иначе демо-фраза накладывалась бы поверх звучащей книги
    /// (оба используют одну и ту же `AVAudioSession(.playback)`).
    func preview(_ option: VoiceOption, serverURL: String, apiKey: String,
                coordinator: PlaybackCoordinator?) {
        stop()
        coordinator?.active?.speech.pause()
        let isEnglishVoice = option.systemIdentifier.map {
            AVSpeechSynthesisVoice(identifier: $0)?.language.hasPrefix("en-") ?? false
        } ?? false
        let phrase = isEnglishVoice
            ? "Hello, my name is \(option.title). I will gladly read for you"
            : "Привет, меня зовут \(option.title). С радостью могу почитать для тебя"
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

    /// Построение запроса и проверка статуса — через общий `SileroClient`
    /// (тот же тип использует боевой путь `SileroBackend.fetchAudio`). Превью не
    /// ретраит (единичный демо-запрос, не критичный для чтения книги) — ошибка
    /// просто гасится в `try?` вызывающей стороной.
    private static func fetch(base: URL, apiKey: String,
                              speaker: String, text: String) async throws -> Data {
        let req = try SileroClient.makeRequest(baseURL: base, apiKey: apiKey, speaker: speaker,
                                               text: text, timeout: 10)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try SileroClient.validate(resp)
        return data
    }
}
