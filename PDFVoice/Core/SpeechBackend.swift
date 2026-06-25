import Foundation

/// Событие, которое backend шлёт координатору (SpeechEngine).
enum SpeechEvent {
    /// Начато аудио предложения с указанным индексом.
    case didStart(Int)
    /// Синтезатор перешёл к следующему слову (только AVSpeech).
    case didWord(Range<String.Index>)
    /// Вся очередь дочитана до конца.
    case finishedAll
}

/// Шов между координатором SpeechEngine и конкретным движком синтеза.
/// Все вызовы происходят на главном акторе.
@MainActor
protocol SpeechBackend: AnyObject {
    /// Координатор подписывается на этот обработчик сразу после создания backend.
    var onEvent: ((SpeechEvent) -> Void)? { get set }

    /// Начать воспроизведение с позиции `index`.
    /// `render` — замыкание позднего рендера: преобразует `Sentence` в строку для синтеза.
    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> String)

    /// Добавить предложения в уже работающую очередь.
    func append(sentences: [Sentence], render: @escaping (Sentence) -> String)

    func pause()
    func resume()
    func stop()

    /// Применить новую скорость к текущему воспроизведению.
    func setSpeed(_ speed: Double)
}
