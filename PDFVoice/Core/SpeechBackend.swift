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

/// Размеченное представление предложения для синтеза речи.
/// `text` — раскрытый текст (числа/аббревиатуры уже развёрнуты).
/// `stresses` — UTF-16 смещения ударных гласных в `text`;
/// Silero вставляет «+» ПОСЛЕ символа по каждому смещению, AVSpeech игнорирует.
struct SpokenMarkup {
    let text: String
    /// Отсортированные UTF-16 смещения ударных гласных в `text`.
    let stresses: [Int]
}

/// Шов между координатором SpeechEngine и конкретным движком синтеза.
/// Все вызовы происходят на главном акторе.
@MainActor
protocol SpeechBackend: AnyObject {
    /// Координатор подписывается на этот обработчик сразу после создания backend.
    var onEvent: ((SpeechEvent) -> Void)? { get set }

    /// Начать воспроизведение с позиции `index`.
    /// `render` — замыкание позднего рендера: преобразует `Sentence` в `SpokenMarkup` для синтеза.
    func play(sentences: [Sentence], from index: Int,
              speed: Double, render: @escaping (Sentence) -> SpokenMarkup)

    /// Добавить предложения в уже работающую очередь.
    func append(sentences: [Sentence], render: @escaping (Sentence) -> SpokenMarkup)

    func pause()
    func resume()
    func stop()

    /// Применить новую скорость к текущему воспроизведению.
    func setSpeed(_ speed: Double)
}
