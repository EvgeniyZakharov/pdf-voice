import Foundation

/// Абстракция движка озвучки. Сейчас реализация одна — нативный AVSpeechSynthesizer.
/// Шов оставлен, чтобы позже подключить облачный TTS (ElevenLabs/OpenAI) как премиум
/// без переписывания Reader.
@MainActor
protocol TTSProvider: AnyObject {
    /// Загрузить очередь предложений для озвучки, начиная с указанной позиции.
    func load(sentences: [Sentence], startIndex: Int)
    /// Начать/продолжить с указанного предложения.
    func play(from index: Int)
    func pause()
    func resume()
    func stop()
}
