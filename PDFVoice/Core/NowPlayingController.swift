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
        observeState()
        updateNowPlaying()
    }

    // MARK: - Now Playing

    private func observeState() {
        // Обновляем при смене предложения и play/pause (не на каждое слово).
        speech.$currentIndex
            .combineLatest(speech.$isSpeaking)
            .sink { [weak self] _ in
                Task { @MainActor in self?.updateNowPlaying() }
            }
            .store(in: &cancellables)
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyArtist] = "PDF Voice"
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyPlaybackRate] = speech.isSpeaking ? 1.0 : 0.0
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
