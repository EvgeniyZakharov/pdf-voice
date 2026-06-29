import Foundation

/// Владелец активной сессии чтения. Поднят выше `ReaderView`, чтобы воспроизведение
/// переживало уход с экрана читалки (возврат в библиотеку, навигацию внутри приложения).
///
/// Инвариант: одновременно живёт ровно одна сессия (`active`) — один `SpeechEngine`/
/// `AVAudioSession`. Открытие другой книги сносит прежнюю (полный `endSession`).
@MainActor
final class PlaybackCoordinator: ObservableObject {
    /// Текущая сессия чтения (nil — ничего не открыто/не играет).
    @Published private(set) var active: ReaderViewModel?

    private let store: DocumentStore
    private let settings: SettingsStore

    init(store: DocumentStore, settings: SettingsStore) {
        self.store = store
        self.settings = settings
    }

    /// Возвращает сессию для `item`: ту же, если уже открыта, иначе сносит прежнюю и
    /// создаёт новую (с полной настройкой и стартом загрузки). Идемпотентно.
    @discardableResult
    func open(_ item: LibraryItem) -> ReaderViewModel {
        if let m = active, m.itemID == item.id { return m }
        active?.endSession()
        let model = ReaderViewModel(item: item, store: store)
        model.attach(store: store)
        model.applySettings(settings)
        model.load()
        active = model
        return model
    }

    /// Полностью завершает активную сессию (✕ в мини-плеере): пауза + teardown Now Playing.
    func stop() {
        active?.endSession()
        active = nil
    }

    /// Снимает сессию, если она относится к удаляемой книге.
    func stopIfActive(_ itemID: UUID) {
        if active?.itemID == itemID { stop() }
    }
}