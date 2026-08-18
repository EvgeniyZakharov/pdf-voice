import Combine
import Foundation
import MediaPlayer

/// Интеграция с системой: экран блокировки, Пункт управления, наушники.
/// Показывает Now Playing и обрабатывает удалённые команды (play/pause/next/prev).
@MainActor
final class NowPlayingController {

    private let speech: SpeechEngine
    private let title: String
    private var cancellables = Set<AnyCancellable>()
    private var commandTokens: [(MPRemoteCommand, Any)] = []

    init(speech: SpeechEngine, title: String) {
        self.speech = speech
        self.title = title
        setupRemoteCommands()
        setStaticInfo()
        observeState()
        updateProgress()
    }

    // MARK: - Now Playing

    /// Название/автор книги не меняются в рамках одной сессии чтения — ставим
    /// их РОВНО ОДИН раз здесь (контроллер и так пересоздаётся на каждую новую
    /// книгу в `finishLoading`), а не на каждую смену предложения.
    private func setStaticInfo() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "PDF Voice"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func observeState() {
        // Обновляем при смене предложения, play/pause и смене скорости — не на
        // каждое слово (за счёт связки с currentIndex, а не таймером слов).
        speech.$currentIndex
            .combineLatest(speech.$isSpeaking, speech.$speed)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateProgress() }
            }
            .store(in: &cancellables)
    }

    /// Прогресс-бар на экране блокировки — «длительность» и «позиция» в единицах
    /// НОМЕРА ПРЕДЛОЖЕНИЯ (у нас нет посекундной длительности TTS-аудио заранее).
    /// Не трогает title/artist/mediaType — они выставлены один раз в `setStaticInfo`.
    private func updateProgress() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyPlaybackDuration] = Double(max(speech.sentences.count, 1))
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(speech.currentIndex)
        info[MPNowPlayingInfoPropertyPlaybackRate] = speech.isSpeaking ? speech.speed : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Remote Commands

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { [weak self] in self?.speech.resume() }
        add(center.pauseCommand) { [weak self] in self?.speech.pause() }
        add(center.togglePlayPauseCommand) { [weak self] in self?.speech.togglePlayPause() }
        add(center.nextTrackCommand) { [weak self] in self?.speech.skipForward() }
        add(center.previousTrackCommand) { [weak self] in self?.speech.skipBackward() }
    }

    private func add(_ command: MPRemoteCommand, action: @escaping () -> Void) {
        command.isEnabled = true
        let token = command.addTarget { _ in
            Task { @MainActor in action() }
            return .success
        }
        commandTokens.append((command, token))
    }

    // MARK: - Teardown

    func teardown() {
        for (command, token) in commandTokens {
            command.removeTarget(token)
        }
        commandTokens.removeAll()
        cancellables.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
