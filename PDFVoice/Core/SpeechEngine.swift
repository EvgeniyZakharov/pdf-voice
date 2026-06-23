import AVFoundation
import Foundation

// MARK: - Silero request body

private struct SileroRequest: Encodable {
    let text: String
    let speaker: String
}

/// Нативный движок озвучки поверх AVSpeechSynthesizer.
///
/// Все оставшиеся предложения ставятся в очередь синтезатора разом — он сам
/// проигрывает их подряд. Это исключает повторное чтение, которое возникало
/// при ручной схеме «доречь следующее в didFinish». Подсветка ведётся по
/// делегату `didStart`. Перемотка/смена скорости пере-наполняют очередь с позиции.
@MainActor
final class SpeechEngine: NSObject, ObservableObject, TTSProvider {

    // Состояние для UI
    @Published private(set) var sentences: [Sentence] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var spokenWordRange: Range<String.Index>?

    /// Пауза после каждого предложения (секунды). Применяется при следующей постановке в очередь.
    @Published var pauseBetweenSentences: Double = 0.3

    @Published var voice: AVSpeechSynthesisVoice? = SpeechEngine.bestRussianVoice() {
        didSet {
            guard isSpeaking, voice !== oldValue else { return }
            enqueueRemaining(from: currentIndex)
        }
    }

    /// Доступные множители скорости (1.0 = обычная речь).
    static let speedOptions: [Double] = [0.5, 0.75, 1, 1.2, 1.4, 1.6, 1.8, 2, 2.5]

    /// Текущая скорость. Меняется сразу: очередь пере-наполняется с текущего места.
    @Published var speed: Double = 1.0 {
        didSet {
            guard speed != oldValue, isSpeaking else { return }
            enqueueRemaining(from: currentIndex)
        }
    }

    /// Доступные русские голоса (Enhanced/Premium выше Default).
    let availableRussianVoices: [AVSpeechSynthesisVoice] =
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }

    /// Колбэк прогресса — DocumentStore сохраняет позицию.
    var onIndexChange: ((Int) -> Void)?

    // MARK: - Silero

    /// URL сервера Silero. Если nil — используется AVSpeechSynthesizer.
    var sileroServerURL: URL? = nil
    /// Голос Silero: aidar / baya / kseniya / xenia / eugene
    var sileroSpeaker: String = "xenia"

    private var audioPlayer: AVAudioPlayer?
    private var sileroTask: Task<Void, Never>?

    private let synthesizer = AVSpeechSynthesizer()
    /// Сопоставление поставленного в очередь utterance → индекс предложения.
    private var indexForUtterance: [ObjectIdentifier: Int] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - TTSProvider

    func load(sentences: [Sentence], startIndex: Int = 0) {
        stop()
        self.sentences = sentences
        currentIndex = clamp(startIndex)
    }

    func play(from index: Int) {
        guard !sentences.isEmpty else { return }
        currentIndex = clamp(index)
        activateAudioSession()
        isSpeaking = true
        if sileroServerURL != nil {
            playSilero(from: currentIndex)
        } else {
            enqueueRemaining(from: currentIndex)
        }
    }

    func pause() {
        if sileroServerURL != nil {
            sileroTask?.cancel()
            audioPlayer?.stop()
            audioPlayer = nil
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        isSpeaking = false
    }

    func resume() {
        if sileroServerURL != nil {
            isSpeaking = true
            playSilero(from: currentIndex)
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else {
            play(from: currentIndex)
        }
    }

    /// Единая точка для кнопки play/pause.
    func togglePlayPause() {
        if isSpeaking { pause() } else { resume() }
    }

    func stop() {
        sileroTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        synthesizer.stopSpeaking(at: .immediate)
        indexForUtterance.removeAll()
        isSpeaking = false
        spokenWordRange = nil
    }

    // MARK: - Навигация

    func skipForward() { play(from: currentIndex + 1) }
    func skipBackward() { play(from: currentIndex - 1) }

    // MARK: - Очередь

    /// Ставит в очередь синтезатора все предложения, начиная с `start`.
    /// Предыдущая очередь сбрасывается (старые utterance уйдут в didCancel).
    private func enqueueRemaining(from start: Int) {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        indexForUtterance.removeAll()
        guard sentences.indices.contains(start) else {
            isSpeaking = false
            return
        }
        for i in start..<sentences.count {
            let utterance = AVSpeechUtterance(string: sentences[i].text)
            utterance.voice = voice
            utterance.rate = SpeechEngine.utteranceRate(for: speed)
            utterance.postUtteranceDelay = pauseBetweenSentences
            indexForUtterance[ObjectIdentifier(utterance)] = i
            synthesizer.speak(utterance)
        }
    }

    private func clamp(_ i: Int) -> Int {
        max(0, min(i, max(sentences.count - 1, 0)))
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    /// Перевод множителя скорости в `rate` AVSpeechUtterance.
    static func utteranceRate(for multiplier: Double) -> Float {
        let def = Double(AVSpeechUtteranceDefaultSpeechRate)
        let maxR = Double(AVSpeechUtteranceMaximumSpeechRate)
        let minR = Double(AVSpeechUtteranceMinimumSpeechRate)
        let r = multiplier <= 1
            ? def * multiplier
            : def + (multiplier - 1) / (2.5 - 1) * (maxR - def)
        return Float(min(max(r, minR), maxR))
    }

    /// Лучший доступный русский голос (Enhanced/Premium предпочтительнее Default).
    static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        let russian = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        return russian.first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}

// MARK: - Silero playback

extension SpeechEngine {
    private func playSilero(from index: Int) {
        sileroTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        sileroTask = Task { [weak self] in
            await self?.runSileroQueue(from: index)
        }
    }

    private func runSileroQueue(from startIndex: Int) async {
        var i = startIndex
        while i < sentences.count {
            guard !Task.isCancelled, isSpeaking else { return }
            currentIndex = i
            onIndexChange?(i)
            do {
                let data = try await fetchSileroAudio(sentences[i].text)
                guard !Task.isCancelled, isSpeaking else { return }
                try await playAndWait(data)
            } catch is CancellationError {
                return
            } catch {
                isSpeaking = false
                return
            }
            i += 1
        }
        isSpeaking = false
    }

    private func fetchSileroAudio(_ text: String) async throws -> Data {
        guard let base = sileroServerURL else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("synthesize")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(SileroRequest(text: text, speaker: sileroSpeaker))
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func playAndWait(_ data: Data) async throws {
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.prepareToPlay()
        player.play()
        let nanos = UInt64((player.duration + max(0, pauseBetweenSentences)) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension SpeechEngine: AVSpeechSynthesizerDelegate {
    /// Подсветка обновляется в момент начала аудио предложения.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let index = indexForUtterance[ObjectIdentifier(utterance)] else { return }
            currentIndex = index
            onIndexChange?(index)
            spokenWordRange = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let index = indexForUtterance[ObjectIdentifier(utterance)] else { return }
            indexForUtterance[ObjectIdentifier(utterance)] = nil
            spokenWordRange = nil
            // Очередь дочитана до конца.
            if index >= sentences.count - 1 {
                isSpeaking = false
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let r = Range(characterRange, in: utterance.speechString) {
                spokenWordRange = r
            }
        }
    }
}
