import AVFoundation
import Foundation

/// Backend синтеза речи через локальный/удалённый Silero HTTP-сервер.
///
/// Реализует предзагрузку: сетевой запрос за следующим клипом стартует, пока
/// ещё звучит текущий — между предложениями нет паузы на скачивание. Это
/// критично для фонового режима: iOS усыпляет приложение при тишине, а запрос
/// через туннель может занимать секунды.
@MainActor
final class SileroBackend: SpeechBackend {

    var onEvent: ((SpeechEvent) -> Void)?

    var serverURL: URL?
    var speaker: String = "xenia"
    var apiKey: String = ""
    var pauseBetweenSentences: Double = 0.3
    var headingPause: Double = 0.7

    private var audioPlayer: AVAudioPlayer?
    private var sileroTask: Task<Void, Never>?

    // MARK: - SpeechBackend

    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> String) {
        stop()
        currentSentences = sentences
        currentSpeed = speed
        currentRender = render
        startQueue(from: index)
    }

    func append(sentences: [Sentence], render: @escaping (Sentence) -> String) {
        guard !sentences.isEmpty else { return }
        currentSentences.append(contentsOf: sentences)
        currentRender = render
        // Задача уже работает и читает currentSentences — ничего больше не нужно.
    }

    func pause() {
        sileroTask?.cancel()
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func resume() {
        // Вызывается координатором после pause(); он сам вызывает play(from:) с нужным индексом.
    }

    func stop() {
        sileroTask?.cancel()
        sileroTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
    }

    func setSpeed(_ speed: Double) {
        currentSpeed = speed
        // Применяется к текущему клипу немедленно; следующие тоже будут читать currentSpeed.
        audioPlayer?.rate = Float(speed)
    }

    // MARK: - Внутреннее состояние

    private var currentSentences: [Sentence] = []
    private var currentSpeed: Double = 1.0
    private var currentRender: ((Sentence) -> String)?

    private func startQueue(from index: Int) {
        sileroTask = Task { [weak self] in
            await self?.runQueue(from: index)
        }
    }

    // MARK: - Очередь с предзагрузкой

    private func runQueue(from startIndex: Int) async {
        func prefetch(_ index: Int) -> Task<Data, Error>? {
            guard currentSentences.indices.contains(index),
                  let render = currentRender else { return nil }
            let text = render(currentSentences[index])
            return Task.detached { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.fetchAudio(text)
            }
        }

        var i = startIndex
        var pending = prefetch(i)
        while i < currentSentences.count {
            guard !Task.isCancelled, let current = pending else {
                pending?.cancel()
                return
            }
            onEvent?(.didStart(i))
            let data: Data
            do {
                data = try await current.value
            } catch is CancellationError {
                return
            } catch {
                onEvent?(.finishedAll)
                return
            }
            guard !Task.isCancelled else { return }
            pending = prefetch(i + 1)
            do {
                let extra = currentSentences[i].isHeading ? headingPause : 0
                try await playAndWait(data, extraPause: extra)
            } catch is CancellationError {
                pending?.cancel()
                return
            } catch {
                // Данные не сложились в аудио — пропускаем предложение, не глушим очередь.
                i += 1
                continue
            }
            i += 1
        }
        onEvent?(.finishedAll)
    }

    // MARK: - Сеть

    private struct SileroRequest: Encodable {
        let text: String
        let speaker: String
    }

    private func fetchAudio(_ text: String) async throws -> Data {
        guard let base = serverURL else { throw URLError(.badURL) }
        let url = base.appendingPathComponent("synthesize")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        req.httpBody = try JSONEncoder().encode(SileroRequest(text: text, speaker: speaker))
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    // MARK: - Воспроизведение

    private func playAndWait(_ data: Data, extraPause: Double = 0) async throws {
        let player = try AVAudioPlayer(data: data)
        self.audioPlayer = player
        player.enableRate = true
        player.rate = Float(currentSpeed)
        player.prepareToPlay()
        player.play()
        let clip = player.duration / Double(max(0.5, currentSpeed))
        let pause = max(0, pauseBetweenSentences) + max(0, extraPause)
        let nanos = UInt64((clip + pause) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}
