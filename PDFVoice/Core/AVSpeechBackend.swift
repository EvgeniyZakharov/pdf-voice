import AVFoundation
import Foundation

/// Backend синтеза речи на базе системного AVSpeechSynthesizer.
///
/// Все оставшиеся предложения ставятся в очередь синтезатора разом — он сам
/// проигрывает их подряд. Это исключает повторное чтение, которое возникало
/// при ручной схеме «доречь следующее в didFinish». Подсветка ведётся по
/// делегату `didStart`. Перемотка/смена скорости/голоса пере-наполняют очередь с позиции.
@MainActor
final class AVSpeechBackend: NSObject, SpeechBackend {

    var onEvent: ((SpeechEvent) -> Void)?

    /// Текущий голос синтеза. Смена во время воспроизведения пере-наполняет очередь.
    var voice: AVSpeechSynthesisVoice? = SpeechEngine.bestRussianVoice()

    private let synthesizer = AVSpeechSynthesizer()
    /// Сопоставление ObjectIdentifier utterance → индекс предложения.
    private var indexForUtterance: [ObjectIdentifier: Int] = [:]

    /// Пауза после каждого предложения (сек). Coordinator выставляет перед вызовом play/append.
    var pauseBetweenSentences: Double = 0.3

    // Состояние, необходимое для пере-наполнения очереди при смене speed/voice.
    private var currentSentences: [Sentence] = []
    private var currentSpeed: Double = 1.0
    private var lastStartedIndex: Int = 0
    private var currentRender: ((Sentence) -> String)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Истинно, если синтезатор поставлен на паузу (а не остановлен).
    var isPaused: Bool { synthesizer.isPaused }

    // MARK: - SpeechBackend

    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> String) {
        currentSentences = sentences
        currentSpeed = speed
        currentRender = render
        lastStartedIndex = index
        enqueue(from: index)
    }

    func append(sentences: [Sentence], render: @escaping (Sentence) -> String) {
        guard !sentences.isEmpty else { return }
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        currentSentences.append(contentsOf: sentences)
        // render-замыкание обновляем: новые предложения используют актуальный render.
        currentRender = render
        let appendStart = currentSentences.count - sentences.count
        for i in appendStart..<currentSentences.count {
            enqueueOne(index: i, render: render)
        }
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
    }

    func resume() {
        synthesizer.continueSpeaking()
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        indexForUtterance.removeAll()
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
        // AVSpeechSynthesizer не поддерживает live-смену темпа — пере-наполняем очередь.
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        enqueue(from: lastStartedIndex)
    }

    func setVoice(_ v: AVSpeechSynthesisVoice?) {
        voice = v
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        enqueue(from: lastStartedIndex)
    }

    // MARK: - Внутренняя очередь

    private func enqueue(from start: Int) {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        indexForUtterance.removeAll()
        guard currentSentences.indices.contains(start),
              let render = currentRender else { return }
        for i in start..<currentSentences.count {
            enqueueOne(index: i, render: render)
        }
    }

    private func enqueueOne(index: Int, render: (Sentence) -> String) {
        let s = currentSentences[index]
        let utterance = AVSpeechUtterance(string: render(s))
        utterance.voice = voice
        utterance.rate = SpeechEngine.utteranceRate(for: currentSpeed)
        // headingPause: дополнительная пауза после заголовка главы/раздела.
        let headingPause: Double = 0.7
        utterance.postUtteranceDelay = pauseBetweenSentences + (s.isHeading ? headingPause : 0)
        indexForUtterance[ObjectIdentifier(utterance)] = index
        synthesizer.speak(utterance)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension AVSpeechBackend: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let index = self.indexForUtterance[ObjectIdentifier(utterance)] else { return }
            self.lastStartedIndex = index
            self.onEvent?(.didStart(index))
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard let index = self.indexForUtterance[ObjectIdentifier(utterance)] else { return }
            self.indexForUtterance[ObjectIdentifier(utterance)] = nil
            if index >= self.currentSentences.count - 1 {
                self.onEvent?(.finishedAll)
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let r = Range(characterRange, in: utterance.speechString) {
                self.onEvent?(.didWord(r))
            }
        }
    }
}
