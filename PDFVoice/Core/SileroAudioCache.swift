import Foundation

/// LRU-кэш синтезированных клипов Silero: ключ — (текст с ударениями + спикер),
/// значение — WAV `Data`. `actor`, а не `@MainActor`-свойство: доступ нужен и с
/// MainActor (перед сетевым запросом), и из nonisolated фонового пути `fetchAudio`
/// (см. SileroBackend) — actor сам сериализует обращения без ручных блокировок.
///
/// Устраняет повторное скачивание одного и того же клипа при pause→resume и
/// skipBackward/skipForward по уже озвученным предложениям.
actor SileroAudioCache {
    struct Key: Hashable {
        let text: String
        let speaker: String
    }

    private let capacity: Int
    private var storage: [Key: Data] = [:]
    /// Порядок доступа: голова — самый давно использованный, хвост — самый свежий.
    private var usageOrder: [Key] = []

    init(capacity: Int = 25) {
        self.capacity = capacity
    }

    func data(for key: Key) -> Data? {
        guard let cached = storage[key] else { return nil }
        markUsed(key)
        return cached
    }

    func store(_ data: Data, for key: Key) {
        if storage[key] == nil {
            usageOrder.append(key)
        } else {
            markUsed(key)
        }
        storage[key] = data
        evictIfNeeded()
    }

    private func markUsed(_ key: Key) {
        if let idx = usageOrder.firstIndex(of: key) {
            usageOrder.remove(at: idx)
        }
        usageOrder.append(key)
    }

    private func evictIfNeeded() {
        while storage.count > capacity, !usageOrder.isEmpty {
            let oldest = usageOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
