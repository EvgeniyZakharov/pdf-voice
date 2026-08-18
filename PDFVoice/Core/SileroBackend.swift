import AVFoundation
import Foundation

/// Backend синтеза речи через локальный/удалённый Silero HTTP-сервер.
///
/// Реализует предзагрузку (глубина 2): сетевые запросы за следующими клипами стартуют,
/// пока ещё звучит текущий — между предложениями нет паузы на скачивание. Это критично
/// для фонового режима: iOS усыпляет приложение при тишине, а запрос через туннель
/// может занимать секунды.
///
/// Завершение клипа определяется через `AVAudioPlayerDelegate` (а не расчётный
/// `Task.sleep`), поэтому смена скорости посреди клипа не рвёт расписание очереди —
/// `AVAudioPlayer.rate` можно менять на лету, делегат сработает по фактическому
/// завершению воспроизведения независимо от темпа. Тот же механизм даёт истинный
/// pause/resume «бесплатно»: pause() на середине клипа НЕ отменяет фоновую задачу
/// очереди — она остаётся подвешенной на continuation до resume()/stop().
@MainActor
final class SileroBackend: NSObject, SpeechBackend {

    var onEvent: ((SpeechEvent) -> Void)?

    var serverURL: URL?
    var speaker: String = "xenia"
    var apiKey: String = ""
    var pauseBetweenSentences: Double = 0.3
    var headingPause: Double = 0.7

    private var audioPlayer: AVAudioPlayer?
    private var sileroTask: Task<Void, Never>?
    /// true когда pause() остановил воспроизведение посреди клипа (плеер жив,
    /// currentTime сохранён) — sileroTask НЕ отменяется в этом случае, см. pause().
    private(set) var isPausedMidClip = false
    /// Индекс предложения, чей клип сейчас играет (или последним играл).
    private var queueIndex = 0

    /// Continuation текущего `playAndWait` — резюмится либо делегатом (естественное
    /// завершение), либо явно при stop()/отмене (см. finishPlayback).
    private var finishContinuation: CheckedContinuation<Void, Error>?

    /// Префетч-задачи (глубина 2), явно отменяемые в pause()/stop() (Р8) — Task.detached
    /// не является дочерней задачей sileroTask, отмена sileroTask её НЕ затрагивает.
    private var prefetchTask1: Task<AudioFetchResult, Error>?
    private var prefetchTask2: Task<AudioFetchResult, Error>?

    private let audioCache = SileroAudioCache(capacity: 25)

    /// `nonisolated` — читаются из nonisolated-сетевого пути (fetchAudio) и из
    /// static chunk(_:), которая тоже nonisolated (чистая функция, тестируется
    /// в харнессе без MainActor).
    private nonisolated static let requestTimeout: TimeInterval = 10
    private nonisolated static let maxAttempts = 2
    private nonisolated static let retryBackoff: TimeInterval = 0.5
    /// Лимит длины куска, отправляемого на сервер за один запрос (сервер отклоняет
    /// текст длиннее ~800 символов — режем с запасом).
    private nonisolated static let maxChunkLength = 700

    // MARK: - SpeechBackend

    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> SpokenMarkup) {
        stop()
        currentSentences = sentences
        currentSpeed = speed
        currentRender = render
        startQueue(from: index)
    }

    func append(sentences: [Sentence], render: @escaping (Sentence) -> SpokenMarkup) {
        guard !sentences.isEmpty else { return }
        currentSentences.append(contentsOf: sentences)
        currentRender = render
        // Задача уже работает и читает currentSentences — ничего больше не нужно.
    }

    /// Пауза. Различает два случая:
    /// - Посреди клипа (плеер жив, currentTime в пределах (0, duration)) — просто
    ///   ставим AVAudioPlayer на паузу. sileroTask НЕ трогаем: он подвешен внутри
    ///   playAndWait на continuation, которая резюмится делегатом, когда клип
    ///   доиграет ПОСЛЕ resume(). Действующий префетч (следующее предложение)
    ///   продолжает качаться в фоне — он пригодится сразу после resume().
    /// - Между клипами (сеть/пауза-разделитель) — там воспроизводить ещё нечего,
    ///   поэтому жёстко отменяем sileroTask и префетчи; resume() перезапустит
    ///   очередь с queueIndex + 1.
    func pause() {
        guard let player = audioPlayer else {
            hardCancelForPause()
            return
        }
        let midClip = player.currentTime > 0 && player.currentTime < player.duration
        if midClip {
            player.pause()
            isPausedMidClip = true
        } else {
            hardCancelForPause()
        }
    }

    private func hardCancelForPause() {
        sileroTask?.cancel()
        sileroTask = nil
        prefetchTask1?.cancel()
        prefetchTask1 = nil
        prefetchTask2?.cancel()
        prefetchTask2 = nil
        isPausedMidClip = false
    }

    func resume() {
        if isPausedMidClip, let player = audioPlayer {
            isPausedMidClip = false
            player.play()
            // sileroTask уже подвешен на continuation того же клипа — ничего
            // больше запускать не нужно, делегат доиграет и продолжит очередь.
            return
        }
        // Жёсткая пауза (или ничего не игралось): перезапускаем с места, где
        // остановились — currentIndex "владеет" координатор (SpeechEngine),
        // здесь достаточно продолжить с последнего начатого предложения + 1.
        startQueue(from: queueIndex + 1)
    }

    func stop() {
        sileroTask?.cancel()
        sileroTask = nil
        prefetchTask1?.cancel()
        prefetchTask1 = nil
        prefetchTask2?.cancel()
        prefetchTask2 = nil
        audioPlayer?.stop()
        audioPlayer = nil
        isPausedMidClip = false
        finishPlayback(error: CancellationError())
        // См. AVSpeechBackend.stop(): отпускаем замыкание рендера, чтобы не
        // держать (пусть и слабую) ссылку на устаревшую очередь дольше нужного.
        currentRender = nil
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
        // AVAudioPlayer.rate можно менять в любой момент (играет/на паузе) — не
        // запускает и не останавливает воспроизведение само по себе. Делегат по-прежнему
        // сработает по фактическому завершению клипа на новой скорости.
        audioPlayer?.rate = Float(speed)
    }

    // MARK: - Внутреннее состояние

    private var currentSentences: [Sentence] = []
    private var currentSpeed: Double = 1.0
    private var currentRender: ((Sentence) -> SpokenMarkup)?

    private func startQueue(from index: Int) {
        sileroTask = Task { [weak self] in
            await self?.runQueue(from: index)
        }
    }

    // MARK: - Очередь с предзагрузкой (глубина 2)

    /// Вставляет «+» ПОСЛЕ каждой ударной гласной по UTF-16 смещениям из SpokenMarkup.
    /// Вставка идёт с конца к началу, чтобы ранее вычисленные смещения не съезжали.
    private static func applyStresses(_ markup: SpokenMarkup) -> String {
        guard !markup.stresses.isEmpty else { return markup.text }
        var utf16 = Array(markup.text.utf16)
        let plus = "+".utf16.first!
        for offset in markup.stresses.reversed() {
            guard offset >= 0 && offset < utf16.count else { continue }
            utf16.insert(plus, at: offset + 1)
        }
        return String(decoding: utf16, as: UTF16.self)
    }

    /// Режет уже отрендеренный (с «+»-ударениями) текст на куски ≤ maxLength по
    /// границам пунктуации/пробела — сервер отклоняет слишком длинный текст одним
    /// запросом (страница без точек может дать «предложение» на тысячи символов).
    /// Куски конкатенируются обратно в исходную строку без потерь (сепараторы
    /// остаются в предыдущем куске, не обрезаются).
    nonisolated static func chunk(_ text: String, maxLength: Int = SileroBackend.maxChunkLength) -> [String] {
        guard text.count > maxLength else { return [text] }
        var pieces: [String] = []
        var remaining = Substring(text)
        while remaining.count > maxLength {
            let window = remaining.prefix(maxLength)
            let splitIndex = bestBoundary(in: window) ?? window.endIndex
            let piece = remaining[remaining.startIndex..<splitIndex]
            guard !piece.isEmpty else {
                // Разделитель нашёлся в самом начале окна — не даём зациклиться,
                // режем жёстко по maxLength.
                let hard = window.endIndex
                pieces.append(String(remaining[remaining.startIndex..<hard]))
                remaining = remaining[hard...]
                continue
            }
            pieces.append(String(piece))
            remaining = remaining[splitIndex...]
        }
        if !remaining.isEmpty {
            pieces.append(String(remaining))
        }
        return pieces
    }

    /// Ищет ПОСЛЕДНЮЮ (ближе к концу окна) границу по приоритету «. » > «; » > «, » > « »,
    /// возвращает индекс СРАЗУ ПОСЛЕ разделителя (разделитель остаётся в предыдущем куске).
    private nonisolated static func bestBoundary(in window: Substring) -> String.Index? {
        for sep in [". ", "; ", ", ", " "] {
            if let r = window.range(of: sep, options: .backwards) {
                return r.upperBound
            }
        }
        return nil
    }

    /// Результат подготовки клипов предложения: готовые к воспроизведению плееры
    /// (обычно один, несколько — если текст пришлось резать), либо «рендер пуст —
    /// сетевого запроса не было» (например, предложение-ссылка вырезана `stripLinks`).
    private enum AudioFetchResult {
        case players([AVAudioPlayer])
        case empty
    }

    private func runQueue(from startIndex: Int) async {
        // Пустая очередь: не слать finishedAll — координатору нечего было играть,
        // это не «дочитали книгу».
        guard !currentSentences.isEmpty else { return }

        var i = startIndex
        // pending1/pending2 живут в prefetchTask1/prefetchTask2 (instance-свойства),
        // а не в локальных переменных — pause()/stop() должны уметь отменить именно
        // ТЕ задачи, что реально в полёте (см. Р8: Task.detached не дочерний, отмена
        // sileroTask его не затрагивает).
        prefetchTask1 = prefetch(i)
        prefetchTask2 = prefetch(i + 1)
        while i < currentSentences.count {
            guard !Task.isCancelled, let current = prefetchTask1 else {
                prefetchTask1?.cancel()
                prefetchTask2?.cancel()
                return
            }
            let result: AudioFetchResult
            do {
                result = try await current.value
            } catch is CancellationError {
                return
            } catch SileroClient.ContentError.rejected(let code) {
                // 4xx (кроме 429) — контентная ошибка (например, сервер не принял
                // пустой/невалидный текст после раскрытия предложения), а не сбой
                // сервиса. НЕ повод откатываться на системный голос — пропускаем
                // это предложение и продолжаем очередь тем же backend'ом.
                #if DEBUG
                print("Silero: sentence \(i) rejected by server (\(code)), skipping")
                #endif
                i += 1
                prefetchTask1 = prefetchTask2
                prefetchTask2 = prefetch(i + 1)
                continue
            } catch {
                // Сеть/5xx → координатор откатится на системный голос с этого
                // предложения. На отмене (stop/переключение backend'а) — молчим,
                // иначе откат сработал бы ложно.
                if !Task.isCancelled { onEvent?(.failed(i)) }
                return
            }
            guard !Task.isCancelled else { return }
            // Сдвигаем окно предзагрузки: то, что было "вторым", становится
            // "первым", и стартуем фетч следующего за ним.
            prefetchTask1 = prefetchTask2
            prefetchTask2 = prefetch(i + 2)

            queueIndex = i
            onEvent?(.didStart(i))

            switch result {
            case .empty:
                // Рендер дал пустой текст — без сетевого запроса, просто
                // выдерживаем паузу между предложениями и идём дальше.
                let extra = currentSentences[i].isHeading ? headingPause : 0
                let pauseAfter = max(0, pauseBetweenSentences) + max(0, extra)
                do { try await Task.sleep(nanoseconds: UInt64(pauseAfter * 1_000_000_000)) }
                catch { return }
            case .players(let players):
                let extra = currentSentences[i].isHeading ? headingPause : 0
                do {
                    for (idx, player) in players.enumerated() {
                        let isLast = idx == players.count - 1
                        // Пауза после предложения — только после ПОСЛЕДНЕГО куска;
                        // между кусками одного предложения читаем подряд без пауз.
                        let pauseAfter = isLast ? (max(0, pauseBetweenSentences) + max(0, extra)) : 0
                        try await playAndWait(player, pauseAfter: pauseAfter)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Данные не сложились в аудио — пропускаем предложение, не глушим очередь.
                }
            }
            i += 1
        }
        onEvent?(.finishedAll)
    }

    /// Готовит клипы (обычно один, несколько — если пришлось резать длинный текст)
    /// для предложения `index`. Повторный вызов для уже запрошенного индекса не
    /// нужен — окно предзагрузки сдвигается без пересоздания задач.
    private func prefetch(_ index: Int) -> Task<AudioFetchResult, Error>? {
        guard currentSentences.indices.contains(index),
              let render = currentRender else { return nil }
        let markup = render(currentSentences[index])
        let trimmed = markup.text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // Явная аннотация типа: без неё компилятор выводит Task<_, Never>
            // (замыкание не throws), а объявленный тип функции — Task<_, Error>.
            return Task<AudioFetchResult, Error> { .empty }
        }
        let fullText = SileroBackend.applyStresses(markup)
        let chunks = SileroBackend.chunk(fullText)
        let speaker = self.speaker
        let serverURL = self.serverURL
        let apiKey = self.apiKey
        let cache = self.audioCache
        return Task.detached {
            var players: [AVAudioPlayer] = []
            players.reserveCapacity(chunks.count)
            for chunkText in chunks {
                let key = SileroAudioCache.Key(text: chunkText, speaker: speaker)
                let data = try await SileroBackend.fetchAudio(
                    chunkText, key: key, cache: cache,
                    serverURL: serverURL, apiKey: apiKey, speaker: speaker)
                let player = try AVAudioPlayer(data: data)
                player.enableRate = true
                player.prepareToPlay()
                players.append(player)
            }
            return .players(players)
        }
    }

    // MARK: - Сеть (nonisolated — выполняется вне MainActor)

    /// Сетевой запрос + чтение/запись LRU-кэша. `nonisolated static` — не трогает
    /// MainActor вообще: все параметры переданы копиями значений, доступ к кэшу
    /// синхронизирован самим `actor SileroAudioCache`. Раньше это был @MainActor-метод
    /// (JSON-энкод, сборка WAV, ретрай-сны на главном потоке) — блокировало UI-поток
    /// на время сети. Построение запроса/классификация статуса — через общий
    /// `SileroClient` (тот же строитель использует `VoicePreviewer`); ретраи/бэкофф/
    /// кэш остаются здесь — они специфичны для боевой очереди озвучки.
    private nonisolated static func fetchAudio(
        _ text: String, key: SileroAudioCache.Key, cache: SileroAudioCache,
        serverURL: URL?, apiKey: String, speaker: String
    ) async throws -> Data {
        if let cached = await cache.data(for: key) { return cached }
        guard let base = serverURL else { throw URLError(.badURL) }
        let req = try SileroClient.makeRequest(baseURL: base, apiKey: apiKey, speaker: speaker,
                                               text: text, timeout: requestTimeout)

        // Ретраи с бэкоффом на ТРАНЗИЕНТНЫХ сбоях (таймаут, обрыв соединения,
        // фон-throttling сети, 5xx, 429 — rate limit). Иначе одна временная ошибка
        // (свернул приложение, другой звук перехватил сеть) → .failed → откат на
        // системный голос. Фатальные ошибки (401/403/404 — неверный ключ/адрес,
        // либо контент, который сервер не принял) НЕ ретраим — сразу пробрасываем,
        // 4xx (кроме 429) — как контентную ошибку, не сетевую.
        var attempt = 0
        while true {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    let retryableStatus = (500...599).contains(http.statusCode) || http.statusCode == 429
                    if retryableStatus, attempt < maxAttempts - 1 {
                        attempt += 1
                        try await Task.sleep(nanoseconds: UInt64(retryBackoff * 1_000_000_000))
                        continue
                    }
                    try SileroClient.validate(resp)
                }
                await cache.store(data, for: key)
                return data
            } catch let error as URLError where isTransient(error) && attempt < maxAttempts - 1 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(retryBackoff * 1_000_000_000))
                continue
            }
        }
    }

    /// Временный ли это сетевой сбой (стоит повторить), в отличие от фатального
    /// (неверный ключ/адрес — повтор бессмыслен).
    private nonisolated static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .resourceUnavailable, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }

    // MARK: - Воспроизведение

    /// Проигрывает уже подготовленный (prepareToPlay вызван off-main в prefetch)
    /// плеер и ждёт ЕСТЕСТВЕННОГО завершения через AVAudioPlayerDelegate — не
    /// расчётный Task.sleep(duration/rate). Это делает смену скорости посреди
    /// клипа безопасной: rate можно менять в любой момент, делегат сработает
    /// когда клип реально доиграет на актуальном темпе.
    private func playAndWait(_ player: AVAudioPlayer, pauseAfter: Double) async throws {
        player.delegate = self
        audioPlayer = player
        player.rate = Float(currentSpeed)
        player.play()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.finishContinuation = cont
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPlayback(error: CancellationError())
            }
        }
        guard pauseAfter > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(pauseAfter * 1_000_000_000))
    }

    /// Резюмирует continuation текущего playAndWait ровно один раз — источники:
    /// естественное завершение (делегат), decode-ошибка (делегат) или явная отмена
    /// (stop()/withTaskCancellationHandler.onCancel). guard защищает от двойного
    /// resume, если несколько источников сработают почти одновременно.
    private func finishPlayback(error: Error?) {
        guard let cont = finishContinuation else { return }
        finishContinuation = nil
        if let error {
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }
}

// MARK: - AVAudioPlayerDelegate

extension SileroBackend: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.finishPlayback(error: nil)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.finishPlayback(error: error ?? URLError(.cannotDecodeContentData))
        }
    }
}
