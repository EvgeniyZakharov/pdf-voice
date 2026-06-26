import AVFoundation
import Foundation

/// Координатор озвучки: держит публичный API и делегирует воспроизведение
/// одному из двух backend'ов — AVSpeechBackend или SileroBackend.
///
/// Все @Published свойства и методы сохранены без изменений —
/// ReaderView, ReaderViewModel, NowPlayingController, SettingsView не требуют правок.
@MainActor
final class SpeechEngine: NSObject, ObservableObject, TTSProvider {

    // MARK: - Публичное состояние для UI

    @Published private(set) var sentences: [Sentence] = []
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var isSpeaking: Bool = false
    @Published private(set) var spokenWordRange: Range<String.Index>?

    /// Пауза после каждого предложения (секунды).
    @Published var pauseBetweenSentences: Double = 0.3 {
        didSet {
            avBackend.pauseBetweenSentences = pauseBetweenSentences
            sileroBackend.pauseBetweenSentences = pauseBetweenSentences
        }
    }

    @Published var voice: AVSpeechSynthesisVoice? = SpeechEngine.bestRussianVoice() {
        didSet {
            guard isSpeaking, voice !== oldValue, sileroServerURL == nil else { return }
            avBackend.setVoice(voice)
        }
    }

    /// Доступные множители скорости (1.0 = обычная речь).
    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @Published var speed: Double = 1.0 {
        didSet {
            guard speed != oldValue, isSpeaking else { return }
            active.setSpeed(speed)
        }
    }

    let availableRussianVoices: [AVSpeechSynthesisVoice] =
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }

    var onIndexChange: ((Int) -> Void)?

    // MARK: - Silero-конфиг (сеттеры переключают active backend)

    var sileroServerURL: URL? = nil {
        didSet {
            sileroBackend.serverURL = sileroServerURL
            let next: SpeechBackend = sileroServerURL != nil ? sileroBackend : avBackend
            // Только при РЕАЛЬНОЙ смене backend'а: глушим уходящий, иначе он
            // продолжит звучать (AVSpeech дочитывает очередь, Silero — свой цикл)
            // и при следующем play/skip наложится второй голос.
            guard next !== active else { return }
            let wasSpeaking = isSpeaking
            active.stop()
            active = next
            // Продолжаем с текущего предложения новым движком (как при смене
            // голоса/скорости внутри одного backend'а), а не обрываем озвучку.
            if wasSpeaking { play(from: currentIndex) }
        }
    }

    var sileroSpeaker: String = "xenia" {
        didSet { sileroBackend.speaker = sileroSpeaker }
    }

    var sileroAPIKey: String = "" {
        didSet { sileroBackend.apiKey = sileroAPIKey }
    }

    // MARK: - Backend'ы

    private let avBackend = AVSpeechBackend()
    private let sileroBackend = SileroBackend()
    private var active: SpeechBackend

    // MARK: - Прерывания

    private var interruptionObserver: Any?

    override init() {
        active = avBackend
        super.init()
        wireBackend(avBackend)
        wireBackend(sileroBackend)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in self?.handleAudioInterruption(note) }
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func wireBackend(_ backend: SpeechBackend) {
        backend.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .didStart(let i):
                self.currentIndex = i
                self.onIndexChange?(i)
                self.spokenWordRange = nil
            case .didWord(let r):
                self.spokenWordRange = r
            case .finishedAll:
                self.isSpeaking = false
            case .failed(let i):
                self.fallBackToSystemVoice(from: i)
            }
        }
    }

    /// Silero-сервер недоступен: беззвучно переключаемся на системный голос и
    /// продолжаем озвучку с того же предложения. Присвоение `sileroServerURL = nil`
    /// в своём didSet остановит Silero, сделает active = avBackend и (т.к. isSpeaking
    /// ещё true) доиграет очередь с `currentIndex` системным движком.
    private func fallBackToSystemVoice(from index: Int) {
        guard active === sileroBackend else { isSpeaking = false; return }
        currentIndex = clamp(index)
        sileroServerURL = nil
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
        sentences.append(contentsOf: newSentences)
        active.append(sentences: newSentences, render: render(_:))
    }

    func play(from index: Int) {
        guard !sentences.isEmpty else { return }
        currentIndex = clamp(index)
        activateAudioSession()
        isSpeaking = true
        active.play(sentences: sentences, from: currentIndex,
                    speed: speed, render: render(_:))
    }

    func pause() {
        active.pause()
        isSpeaking = false
    }

    func resume() {
        // Категория .playback нужна для фона/экрана блокировки. Раньше её ставил
        // только play(from:), а старт Silero через большую кнопку Play идёт по
        // resume() → звук оставался в дефолтной soloAmbient и глох при сворачивании.
        activateAudioSession()
        if sileroServerURL != nil {
            isSpeaking = true
            // Silero не поддерживает истинный pause/resume — перезапускаем с текущей позиции.
            active.play(sentences: sentences, from: currentIndex,
                        speed: speed, render: render(_:))
        } else {
            // AVSpeech: если синтезатор на паузе — продолжаем; иначе — play с начала.
            if avBackend.isPaused {
                avBackend.resume()
                isSpeaking = true
            } else {
                play(from: currentIndex)
            }
        }
    }

    func togglePlayPause() {
        if isSpeaking { pause() } else { resume() }
    }

    func stop() {
        active.stop()
        isSpeaking = false
        spokenWordRange = nil
    }

    // MARK: - Навигация

    func skipForward()  { play(from: currentIndex + 1) }
    func skipBackward() { play(from: currentIndex - 1) }

    /// Перемещает курсор без запуска воспроизведения.
    func seekSilent(to index: Int) {
        guard !isSpeaking else { return }
        currentIndex = clamp(index)
    }

    // MARK: - Рендер предложения

    private let profile: any LanguageProfile = RussianProfile()

    private func render(_ s: Sentence) -> SpokenMarkup {
        let m = profile.render(s.rawText)
        return m.text.trimmingCharacters(in: .whitespaces).isEmpty
            ? SpokenMarkup(text: " ", stresses: [])
            : m
    }

    // MARK: - Вспомогательные

    private func clamp(_ i: Int) -> Int {
        max(0, min(i, max(sentences.count - 1, 0)))
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio)
        try? session.setActive(true)
    }

    // MARK: - Статические хелперы (использует SettingsView и VoiceCatalog)

    static func utteranceRate(for multiplier: Double) -> Float {
        let def = Double(AVSpeechUtteranceDefaultSpeechRate)
        let maxR = Double(AVSpeechUtteranceMaximumSpeechRate)
        let minR = Double(AVSpeechUtteranceMinimumSpeechRate)
        let r = multiplier <= 1
            ? def * multiplier
            : def + (multiplier - 1) / (2.0 - 1) * (maxR - def)
        return Float(min(max(r, minR), maxR))
    }

    static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        let russian = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "ru-RU" }
            .sorted { $0.quality.rawValue > $1.quality.rawValue }
        return russian.first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}
