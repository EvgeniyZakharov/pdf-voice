import AVFoundation
import Foundation

/// Backend синтеза речи на базе системного AVSpeechSynthesizer.
///
/// Оконная очередь (WINDOW_SIZE предложений): вместо постановки всего массива разом
/// держим в синтезаторе окно ~50 предложений и дозаполняем его по мере воспроизведения
/// через didFinish (рефилл). Это устраняет многосекундный фриз при первом Play на
/// reflow-книгах (FB2/EPUB могут содержать десятки тысяч предложений).
///
/// Инвариант «нет повторного чтения» сохранён: рефилл всегда добавляет строго следующие
/// за windowEnd предложения — очередь синтезатора никогда не обнуляется между рефиллами,
/// только дополняется. finishedAll отправляется ровно когда заканчивается предложение
/// с индексом currentSentences.count - 1 (не раньше и не позже).
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
    private var currentRender: ((Sentence) -> SpokenMarkup)?

    // Оконная очередь: в синтезаторе держим не более windowSize предложений.
    // Рефилл запускается из didFinish, когда до конца окна остаётся refillMargin предложений.
    private static let windowSize   = 50
    private static let refillMargin = 20
    /// Индекс последнего предложения, поставленного в очередь синтезатора.
    /// -1 означает «очередь пуста / не инициализирована».
    private var windowEnd: Int = -1

    /// true, если setSpeed() пришёл, пока синтезатор БЫЛ НА ПАУЗЕ — новую скорость
    /// запомнили (currentSpeed), но очередь не пере-наполняли (это стартовало бы
    /// звук немедленно, ломая паузу). resume() при этом флаге пере-наполнит очередь
    /// на актуальной скорости вместо простого continueSpeaking().
    private var speedDirtyWhilePaused = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Истинно, если синтезатор поставлен на паузу (а не остановлен).
    var isPaused: Bool { synthesizer.isPaused }

    // MARK: - SpeechBackend

    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> SpokenMarkup) {
        currentSentences = sentences
        currentSpeed = speed
        currentRender = render
        lastStartedIndex = index
        enqueue(from: index)
    }

    func append(sentences: [Sentence], render: @escaping (Sentence) -> SpokenMarkup) {
        guard !sentences.isEmpty else { return }
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        let oldCount = currentSentences.count
        currentSentences.append(contentsOf: sentences)
        currentRender = render
        // Расширяем окно только если предыдущий «конец очереди» уже был поставлен
        // в синтезатор (windowEnd == oldCount - 1). Если нет — didFinish-рефилл
        // доберётся до новых предложений самостоятельно по мере воспроизведения.
        guard windowEnd == oldCount - 1 else { return }
        let appendStart = windowEnd + 1
        let appendEnd = min(windowEnd + AVSpeechBackend.windowSize, currentSentences.count - 1)
        guard appendStart <= appendEnd else { return }
        for i in appendStart...appendEnd {
            enqueueOne(index: i, render: render)
        }
        windowEnd = appendEnd
    }

    func pause() {
        // .immediate, не .word: у ряда русских голосов (Milena и др.) пауза
        // «по границе слова» фактически срабатывает лишь на границе utterance —
        // кнопка не останавливала чтение посреди предложения. continueSpeaking
        // продолжает с места мгновенной паузы.
        synthesizer.pauseSpeaking(at: .immediate)
    }

    func resume() {
        if speedDirtyWhilePaused {
            // Скорость поменяли, пока стояли на паузе: continueSpeaking() продолжил
            // бы текущую (и все уже поставленные в очередь) utterance на СТАРОМ rate
            // — AVSpeechUtterance.rate фиксируется при создании. Пере-наполняем окно
            // с той же позиции на актуальной скорости; это и есть "старт", которого
            // resume() и ждёт от пользователя (в отличие от setSpeed() ВО ВРЕМЯ паузы,
            // которая не должна звучать раньше явного resume()).
            speedDirtyWhilePaused = false
            enqueue(from: lastStartedIndex)
            return
        }
        synthesizer.continueSpeaking()
    }

    func stop() {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        indexForUtterance.removeAll()
        windowEnd = -1
        speedDirtyWhilePaused = false
        // Обнуляем замыкание рендера: оно захватывает SpeechEngine (пусть и слабо),
        // но держать ссылку на устаревший рендер после stop() смысла нет — и это
        // единственное место, где backend отпускает предыдущую очередь целиком.
        currentRender = nil
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
        if synthesizer.isSpeaking {
            // Уже играем — пере-наполнение стартует звук немедленно, это ожидаемо
            // (аналог смены голоса на лету): AVSpeechSynthesizer не умеет менять rate
            // у уже созданных utterance, только пересоздать их.
            enqueue(from: lastStartedIndex)
        } else if synthesizer.isPaused {
            // На паузе НЕЛЬЗЯ пере-наполнять очередь сейчас: stopSpeaking(.immediate)
            // внутри enqueue() снимает синтезатор с паузы, а последующий speak()
            // тут же начинает звучать — пользователь слышал бы обрыв тишины без
            // нажатия Play. Запоминаем и откладываем до resume().
            speedDirtyWhilePaused = true
        }
        // else: backend неактивен (не играет и не на паузе) — currentSpeed просто
        // запомнен для следующего play().
    }

    func setVoice(_ v: AVSpeechSynthesisVoice?) {
        voice = v
        guard synthesizer.isSpeaking || synthesizer.isPaused else { return }
        enqueue(from: lastStartedIndex)
    }

    // MARK: - Внутренняя очередь

    /// Сбрасывает синтезатор и ставит окно [start, start+windowSize) предложений.
    private func enqueue(from start: Int) {
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        indexForUtterance.removeAll()
        windowEnd = -1
        speedDirtyWhilePaused = false
        guard currentSentences.indices.contains(start),
              let render = currentRender else { return }
        let end = min(start + AVSpeechBackend.windowSize - 1, currentSentences.count - 1)
        for i in start...end {
            enqueueOne(index: i, render: render)
        }
        windowEnd = end
    }

    private func enqueueOne(index: Int, render: (Sentence) -> SpokenMarkup) {
        let s = currentSentences[index]
        // AVSpeech ignores stress marks (Milena doesn't honour U+0301); use plain text only.
        let utterance = AVSpeechUtterance(string: render(s).text)
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

            // finishedAll — только когда дочитано последнее предложение книги.
            if index >= self.currentSentences.count - 1 {
                self.onEvent?(.finishedAll)
                return
            }

            // Рефилл окна: когда до конца поставленной в очередь части осталось
            // refillMargin предложений — добавляем следующие windowSize.
            // Условие index >= windowEnd - refillMargin гарантирует однократный рефилл
            // на нужном рубеже: после рефилла windowEnd прыгает на windowSize вперёд,
            // и следующий didFinish попадает под условие лишь спустя windowSize - refillMargin
            // предложений (т.е. двойного рефилла не бывает).
            if self.windowEnd < self.currentSentences.count - 1,
               index >= self.windowEnd - AVSpeechBackend.refillMargin {
                guard let render = self.currentRender else { return }
                let refillStart = self.windowEnd + 1
                let refillEnd = min(self.windowEnd + AVSpeechBackend.windowSize,
                                    self.currentSentences.count - 1)
                for i in refillStart...refillEnd {
                    self.enqueueOne(index: i, render: render)
                }
                self.windowEnd = refillEnd
            }
        }
    }
}
