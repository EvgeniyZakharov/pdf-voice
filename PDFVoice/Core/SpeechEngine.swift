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

    /// Пауза после каждого предложения (секунды).
    @Published var pauseBetweenSentences: Double = 0.3 {
        didSet {
            avBackend.pauseBetweenSentences = pauseBetweenSentences
            sileroBackend.pauseBetweenSentences = pauseBetweenSentences
        }
    }

    @Published var voice: AVSpeechSynthesisVoice? = SpeechEngine.bestRussianVoice() {
        didSet {
            // Всегда синхронизируем avBackend.voice, даже если Silero активен —
            // чтобы fallback на системный голос сразу взял актуальный голос.
            // avBackend.setVoice пере-наполняет очередь только если синтезатор играет/на паузе.
            guard voice !== oldValue else { return }
            avBackend.setVoice(voice)
        }
    }

    /// Доступные множители скорости (1.0 = обычная речь).
    static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// Прокидывается в ОБА backend'а, а не только в `active` (Р3): переключение
    /// backend'а (Silero-фолбэк/восстановление) не должно воскрешать старую скорость
    /// у backend'а, который был неактивен на момент смены. Раньше didSet требовал
    /// `isSpeaking` — на паузе смена скорости не долетала до backend'а вовсе, и после
    /// resume() играло на старом темпе. Оба backend'а сами решают, можно ли применить
    /// новую скорость немедленно (играют) или нужно только запомнить и применить на
    /// следующем play()/resume() без самопроизвольного старта звука (на паузе).
    @Published var speed: Double = 1.0 {
        didSet {
            guard speed != oldValue else { return }
            avBackend.setSpeed(speed)
            sileroBackend.setSpeed(speed)
        }
    }

    var onIndexChange: ((Int) -> Void)?
    /// Озвучка дошла до последнего предложения книги (для отметки «Закончено»).
    var onFinishedAll: (() -> Void)?

    /// true, когда в `sentences` загружена ВСЯ книга (не только префикс прогрессивной
    /// загрузки). Выставляется `ReaderViewModel` в момент, когда фоновая загрузка
    /// завершена. Пока false, `finishedAll` от backend'а — это не «дочитано», а
    /// «упёрлись в конец ещё не догруженного префикса» (см. `isStarved`).
    var isFullyLoaded: Bool = false

    /// Backend дочитал весь загруженный ПРЕФИКС предложений, пока книга ещё
    /// грузится фоном («голодание»). `appendSentences` перезапускает воспроизведение
    /// с этого места, когда придут новые предложения.
    private var isStarved = false

    // MARK: - Silero-конфиг (сеттеры переключают active backend)

    var sileroServerURL: URL? = nil {
        didSet {
            sileroBackend.serverURL = sileroServerURL
            // Явная (пере)настройка Silero снимает временный откат на системный голос.
            systemFallbackActive = false
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
    private var routeChangeObserver: Any?
    private var foregroundObserver: Any?

    /// true, если ТЕКУЩАЯ пауза была поставлена нами самими из-за `.began`
    /// прерывания (звонок и т.п.), а не пользователем вручную. Только в этом
    /// случае `.ended`+`.shouldResume` должен сам возобновить чтение — иначе
    /// пользователь, поставивший паузу вручную ПЕРЕД или ВО ВРЕМЯ звонка,
    /// обнаруживал бы книгу снова говорящей после того, как повесил трубку.
    private var pausedByInterruption = false

    /// true, если Silero был временно оставлен ради системного голоса из-за сбоя
    /// (обычно транзиентная сеть в фоне). Конфиг Silero при этом СОХРАНЁН — при
    /// возврате на передний план `retrySileroAfterFallback` вернёт нейроголос.
    private var systemFallbackActive = false

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
        // Выдернули наушники / отключился Bluetooth-динамик и т.п.: iOS по
        // умолчанию продолжает играть через встроенный динамик — книга внезапно
        // "орёт" на весь автобус. Пауза при исчезновении прежнего маршрута —
        // стандартное поведение медиаплееров.
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in self?.handleRouteChange(note) }
        // Возврат приложения на передний план: если в фоне сорвались на системный
        // голос — пробуем восстановить Silero. Имя нотификации задаём строкой, чтобы
        // не тянуть UIKit в Core (эти файлы компилируются и в swiftc-харнессах).
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("UIApplicationDidBecomeActiveNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.retrySileroAfterFallback() }
    }

    deinit {
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = foregroundObserver {
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
            case .finishedAll:
                if self.isFullyLoaded {
                    self.isSpeaking = false
                    self.onFinishedAll?()
                } else {
                    // Книга ещё грузится фоном — backend упёрся в конец загруженного
                    // префикса, это не конец книги. Не гасим isSpeaking (намерение
                    // играть сохраняется), ждём appendSentences.
                    self.isStarved = true
                }
            case .failed(let i):
                self.fallBackToSystemVoice(from: i)
            }
        }
    }

    /// Silero-сервер недоступен: беззвучно переключаемся на системный голос и
    /// продолжаем озвучку с того же предложения. Конфиг Silero НЕ сбрасываем
    /// (`sileroServerURL` остаётся) — ставим флаг `systemFallbackActive`, чтобы при
    /// возврате приложения на передний план вернуть нейроголос. Раньше здесь стояло
    /// `sileroServerURL = nil` → откат был НАВСЕГДА: одна транзиентная ошибка сети в
    /// фоне (свернул приложение / другой звук) меняла голос до конца сессии.
    private func fallBackToSystemVoice(from index: Int) {
        guard active === sileroBackend else { isSpeaking = false; return }
        currentIndex = clamp(index)
        systemFallbackActive = true
        let wasSpeaking = isSpeaking
        active.stop()
        active = avBackend
        if wasSpeaking { play(from: currentIndex) }
    }

    /// Возврат на передний план после временного отката на системный голос:
    /// если Silero настроен — переключаемся обратно и продолжаем с текущего
    /// предложения нейроголосом (первый же запрос повторно проверит сервер;
    /// снова упадёт — снова мягкий откат, тоже восстановимый).
    func retrySileroAfterFallback() {
        guard systemFallbackActive, sileroServerURL != nil, active === avBackend else { return }
        systemFallbackActive = false
        let wasSpeaking = isSpeaking
        active.stop()
        active = sileroBackend
        if wasSpeaking { play(from: currentIndex) }
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // Запоминаем, БЫЛИ ли мы вообще говорящими на момент прерывания — если
            // пользователь уже поставил паузу вручную, isSpeaking уже false, и
            // pausedByInterruption останется false: .ended ниже не станет
            // самовольно запускать чтение, которое пользователь остановил сам.
            pausedByInterruption = isSpeaking
            if isSpeaking { pause() }
        case .ended:
            let opts = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            if pausedByInterruption && opts.contains(.shouldResume) { resume() }
            pausedByInterruption = false
        @unknown default:
            break
        }
    }

    /// Реагируем только на исчезновение прежнего маршрута вывода (наушники
    /// выдернуты/Bluetooth отключился) — остальные причины (например, подключение
    /// нового устройства) не должны прерывать чтение.
    private func handleRouteChange(_ notification: Notification) {
        guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        guard reason == .oldDeviceUnavailable else { return }
        if isSpeaking { pause() }
    }

    // MARK: - TTSProvider

    func load(sentences: [Sentence], startIndex: Int = 0) {
        stop()
        self.sentences = sentences
        currentIndex = clamp(startIndex)
        isFullyLoaded = false
        isStarved = false
    }

    func appendSentences(_ newSentences: [Sentence]) {
        guard !newSentences.isEmpty else { return }
        sentences.append(contentsOf: newSentences)
        active.append(sentences: newSentences, render: renderClosure)
        if isStarved {
            // currentIndex — последнее ПОЛНОСТЬЮ прозвучавшее предложение (didStart
            // на него уже пришёл, backend доиграл его и упёрся в конец префикса).
            // Продолжаем со следующего, чтобы не повторить и не пропустить.
            isStarved = false
            play(from: currentIndex + 1)
        }
    }

    func play(from index: Int) {
        guard !sentences.isEmpty else { return }
        currentIndex = clamp(index)
        activateAudioSession()
        isSpeaking = true
        active.play(sentences: sentences, from: currentIndex,
                    speed: speed, render: renderClosure)
    }

    func pause() {
        active.pause()
        isSpeaking = false
    }

    /// Перечитать текущее предложение с начала активным backend'ом — эффект
    /// «пауза → play»: `play(from:)` в обоих backend'ах сперва глушит старый звук
    /// (AVSpeech `stopSpeaking(.immediate)`, Silero `stop()`), затем стартует
    /// заново. Используется при смене голоса на лету.
    func restartCurrent() {
        guard !sentences.isEmpty else { return }
        play(from: currentIndex)
    }

    func resume() {
        guard !sentences.isEmpty else { return }
        // Категория .playback нужна для фона/экрана блокировки. Раньше её ставил
        // только play(from:), а старт Silero через большую кнопку Play идёт по
        // resume() → звук оставался в дефолтной soloAmbient и глох при сворачивании.
        activateAudioSession()
        // Ветвимся по ФАКТИЧЕСКИ активному backend'у, не по конфигу (Р4): после
        // отката на системный голос (fallBackToSystemVoice) sileroServerURL остаётся
        // non-nil (конфиг сохранён для восстановления), но active уже avBackend —
        // ветвление по конфигу звало Silero-путь на avBackend'е и перечитывало
        // предложение с начала вместо продолжения с места паузы.
        if active === sileroBackend {
            isSpeaking = true
            if sileroBackend.isPausedMidClip {
                // Клип жив, currentTime сохранён — продолжаем с места остановки.
                sileroBackend.resume()
            } else {
                active.play(sentences: sentences, from: currentIndex,
                            speed: speed, render: renderClosure)
            }
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
    }

    /// Полное завершение сессии (не просто пауза): останавливает звук и
    /// деактивирует аудиосессию, чтобы приложение отпустило её (иначе «зомби»-сессия
    /// продолжает реагировать на прерывания/Now Playing после закрытия читалки).
    /// Вызывать только на явном закрытии сессии (✕ в мини-плеере, открытие другой
    /// книги) — НЕ на простом уходе с экрана читалки, где чтение должно продолжаться
    /// в фоне через мини-плеер.
    func shutdown() {
        stop()
        if let token = interruptionObserver {
            NotificationCenter.default.removeObserver(token)
            interruptionObserver = nil
        }
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
            routeChangeObserver = nil
        }
        if let token = foregroundObserver {
            NotificationCenter.default.removeObserver(token)
            foregroundObserver = nil
        }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Навигация

    func skipForward()  {
        guard currentIndex + 1 < sentences.count else { return }
        play(from: currentIndex + 1)
    }
    func skipBackward() { play(from: currentIndex - 1) }

    /// Перейти к предложению, сохранив текущее play/pause.
    /// Играет → продолжить с новой позиции; на паузе → только переставить позицию
    /// (@Published currentIndex → highlight/авто-скролл) и персистировать прогресс.
    func seek(to index: Int) {
        guard !sentences.isEmpty else { return }
        let i = clamp(index)
        if isSpeaking {
            play(from: i)
        } else {
            currentIndex = i
            onIndexChange?(i)
        }
    }

    /// Перемещает курсор без запуска воспроизведения.
    func seekSilent(to index: Int) {
        guard !isSpeaking else { return }
        currentIndex = clamp(index)
    }

    // MARK: - Рендер предложения

    /// Языковой профиль книги: раскрывает предложение при постановке в очередь
    /// (late render). Выставляется из `ReaderViewModel` ДО загрузки предложений —
    /// смена профиля на лету очередь не пере-наполняет.
    var profile: any LanguageProfile = LanguageProfiles.default

    private func render(_ s: Sentence) -> SpokenMarkup {
        let m = profile.render(s.rawText)
        return m.text.trimmingCharacters(in: .whitespaces).isEmpty
            ? SpokenMarkup(text: "", stresses: [])
            : m
    }

    /// Замыкание с ленивым захватом self, передаваемое backend'ам как `render`.
    /// Backend'ы хранят его (`currentRender`) на всё время жизни очереди — сильный
    /// захват `render(_:)`-референса держал бы SpeechEngine живым, пока backend не
    /// обнулит `currentRender` (что раньше не происходило в `stop()`), т.е. навсегда.
    private var renderClosure: (Sentence) -> SpokenMarkup {
        { [weak self] s in self?.render(s) ?? SpokenMarkup(text: "", stresses: []) }
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

    /// Системный голос по умолчанию — тот же, что в выборе (Милена):
    /// один источник истины, чтобы фолбэк не заговорил голосом, которого нет
    /// в списке. См. `VoiceCatalog.systemVoices`.
    static func bestRussianVoice() -> AVSpeechSynthesisVoice? {
        VoiceCatalog.systemVoices().first ?? AVSpeechSynthesisVoice(language: "ru-RU")
    }
}
