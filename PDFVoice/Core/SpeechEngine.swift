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

    /// Доп. пауза после строки-заголовка — отделяет название главы/раздела от текста.
    private let headingPause: Double = 0.7

    @Published var voice: AVSpeechSynthesisVoice? = SpeechEngine.bestRussianVoice() {
        didSet {
            guard isSpeaking, voice !== oldValue, sileroServerURL == nil else { return }
            enqueueRemaining(from: currentIndex)
        }
    }

    /// Доступные множители скорости (1.0 = обычная речь).
    /// Диапазон 0.5–2.0 совпадает с допустимым `rate` у AVAudioPlayer (Silero).
    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// Текущая скорость. Меняется сразу: очередь пере-наполняется с текущего места.
    @Published var speed: Double = 1.0 {
        didSet {
            guard speed != oldValue, isSpeaking else { return }
            if sileroServerURL == nil {
                enqueueRemaining(from: currentIndex)
            } else {
                // Silero: меняем темп текущего клипа сразу, следующие читают `speed`.
                audioPlayer?.rate = Float(speed)
            }
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
    /// API-ключ для удалённого сервера. Пусто — заголовок не отправляется.
    var sileroAPIKey: String = ""

    private var audioPlayer: AVAudioPlayer?
    private var sileroTask: Task<Void, Never>?

    private let synthesizer = AVSpeechSynthesizer()
    /// Сопоставление поставленного в очередь utterance → индекс предложения.
    private var indexForUtterance: [ObjectIdentifier: Int] = [:]

    private var interruptionObserver: Any?

    override init() {
        super.init()
        synthesizer.delegate = self
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            self?.handleAudioInterruption(notification)
        }
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            if isSpeaking { pause() }
        case .ended:
            let opts = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            if opts.contains(.shouldResume) { resume() }
        @unknown default:
            break
        }
    }

    // MARK: - TTSProvider

    func load(sentences: [Sentence], startIndex: Int = 0) {
        stop()
        self.sentences = sentences
        currentIndex = clamp(startIndex)
    }

    func appendSentences(_ newSentences: [Sentence]) {
        guard !newSentences.isEmpty else { return }
        let appendStart = sentences.count
        sentences.append(contentsOf: newSentences)

        guard sileroServerURL == nil else { return }
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }

        for i in appendStart..<sentences.count {
            let utterance = AVSpeechUtterance(string: sentences[i].text)
            utterance.voice = voice
            utterance.rate = SpeechEngine.utteranceRate(for: speed)
            utterance.postUtteranceDelay = pauseBetweenSentences + (sentences[i].isHeading ? headingPause : 0)
            indexForUtterance[ObjectIdentifier(utterance)] = i
            synthesizer.speak(utterance)
        }
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

    /// Перемещает курсор без запуска воспроизведения — для восстановления позиции после фоновой загрузки.
    func seekSilent(to index: Int) {
        guard !isSpeaking else { return }
        currentIndex = clamp(index)
    }

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
            utterance.postUtteranceDelay = pauseBetweenSentences + (sentences[i].isHeading ? headingPause : 0)
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
            : def + (multiplier - 1) / (2.0 - 1) * (maxR - def)
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
        synthesizer.stopSpeaking(at: .immediate)
        indexForUtterance.removeAll()
        sileroTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
        sileroTask = Task { [weak self] in
            await self?.runSileroQueue(from: index)
        }
    }

    /// Проигрывает предложения с предзагрузкой следующего во время текущего.
    ///
    /// Сетевой запрос за следующим клипом стартует, пока ещё звучит текущий,
    /// поэтому между предложениями нет паузы на скачивание. Это критично для
    /// фонового режима: iOS усыпляет свёрнутое приложение, как только звук
    /// прекращается, а сетевой запрос через удалённый сервер мог занимать
    /// секунды тишины — за это время воспроизведение убивалось.
    private func runSileroQueue(from startIndex: Int) async {
        func prefetch(_ index: Int) -> Task<Data, Error>? {
            guard sentences.indices.contains(index) else { return nil }
            let text = sentences[index].text
            return Task.detached { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchSileroAudio(text)
            }
        }

        var i = startIndex
        var pending = prefetch(i)
        while i < sentences.count {
            guard !Task.isCancelled, isSpeaking, let current = pending else {
                pending?.cancel()
                if isSpeaking { isSpeaking = false }
                return
            }
            currentIndex = i
            onIndexChange?(i)
            let data: Data
            do {
                data = try await current.value
            } catch is CancellationError {
                return
            } catch {
                isSpeaking = false
                return
            }
            guard !Task.isCancelled, isSpeaking else { return }
            // Запускаем загрузку следующего предложения ДО проигрывания текущего.
            pending = prefetch(i + 1)
            do {
                let extra = sentences[i].isHeading ? headingPause : 0
                try await playAndWait(data, extraPause: extra)
            } catch is CancellationError {
                pending?.cancel()
                return
            } catch {
                // Данные не сложились в аудио (сервер вернул не-WAV для этого
                // предложения) — пропускаем его и продолжаем чтение, а не глушим
                // всю очередь.
                i += 1
                continue
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
        if !sileroAPIKey.isEmpty {
            req.setValue(sileroAPIKey, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = try JSONEncoder().encode(SileroRequest(text: text, speaker: sileroSpeaker))
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    private func playAndWait(_ data: Data, extraPause: Double = 0) async throws {
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.enableRate = true
        player.rate = Float(speed)            // темп воспроизведения Silero-аудио
        player.prepareToPlay()
        player.play()
        // Длительность клипа сокращается пропорционально темпу.
        let clip = player.duration / Double(max(0.5, speed))
        let pause = max(0, pauseBetweenSentences) + max(0, extraPause)
        let nanos = UInt64((clip + pause) * 1_000_000_000)
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
