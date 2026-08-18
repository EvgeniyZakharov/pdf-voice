import Foundation
import UIKit

/// Лёгкое файловое хранилище библиотеки: список — в JSON, сами PDF — в Documents.
/// Сознательно без SwiftData/Core Data, чтобы держать минимальную iOS 16.0.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    /// Пользовательские коллекции (полки). Персистятся отдельным `collections.json`.
    @Published private(set) var collections: [BookCollection] = []

    private let indexURL: URL
    private let collectionsURL: URL
    private let fileManager = FileManager.default

    /// Прогресс чтения (индекс предложения), накопленный с последнего `flushProgress`,
    /// но ещё НЕ влитый в `items`. `updateProgress` вызывается на каждое озвученное
    /// предложение (~каждые 2-5 с) — если бы она сразу мутировала `items`, это
    /// публиковало бы весь массив (пере-рендер `LibraryView` под читалкой) и писало
    /// JSON на диск так же часто. Дебаунс копит здесь и вливает разом (`flushProgress`).
    private var dirtyProgress: [UUID: Int] = [:]
    private var progressFlushTask: Task<Void, Never>?
    private static let progressFlushInterval: TimeInterval = 8
    private var backgroundObserver: NSObjectProtocol?
    /// Сериализует запись library.json на диск в порядке вызовов `save()` — обычный
    /// `Task.detached` на каждый вызов мог бы завершиться не в том порядке.
    private static let writeQueue = DispatchQueue(label: "com.pdfvoice.documentstore.write", qos: .utility)

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        indexURL = DocumentStore.documentsDirectory.appendingPathComponent("library.json")
        collectionsURL = DocumentStore.documentsDirectory.appendingPathComponent("collections.json")
        load()
        loadCollections()
        // Уход в фон/убийство процесса не ждёт дебаунс-таймер: без форс-flush тут
        // последние несколько секунд прогресса чтения терялись бы.
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flushProgress()
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    // MARK: - Импорт

    /// Копирует выбранную пользователем книгу внутрь Documents и добавляет в библиотеку.
    /// Сохраняет оригинальное расширение — оно определяет `LibraryItem.format`.
    @discardableResult
    func importBook(from sourceURL: URL) throws -> LibraryItem {
        let needsScope = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsScope { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension.lowercased()
        let destName = "\(UUID().uuidString).\(ext)"
        let destURL = DocumentStore.documentsDirectory.appendingPathComponent(destName)
        try fileManager.copyItem(at: sourceURL, to: destURL)

        let title = sourceURL.deletingPathExtension().lastPathComponent
        let item = LibraryItem(fileName: destName, title: title)
        items.insert(item, at: 0)
        save()
        return item
    }

    // MARK: - Изменение прогресса

    /// Копит позицию чтения в памяти (см. `dirtyProgress`) — НЕ пишет на диск и не
    /// публикует `items` сразу. Реальный перенос — по дебаунс-таймеру
    /// (`scheduleProgressFlush`) либо принудительно (`flushProgress`).
    func updateProgress(for itemID: UUID, sentenceIndex: Int) {
        guard items.contains(where: { $0.id == itemID }) else { return }
        dirtyProgress[itemID] = sentenceIndex
        scheduleProgressFlush()
    }

    /// Фиксирует момент открытия книги. В отличие от `updateProgress` (частые
    /// вызовы на каждое предложение) вызывается РОВНО ОДИН раз за сессию чтения
    /// (`ReaderViewModel.attach`).
    func markOpened(_ itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].lastOpened = Date()
        save()
    }

    /// Переносит накопленный «грязный» прогресс в `items` и пишет библиотеку на
    /// диск. Вызывается по дебаунс-таймеру, а также принудительно — на выход из
    /// сессии чтения (`ReaderViewModel.endSession`) и на уход приложения в фон
    /// (`willResignActive`).
    func flushProgress() {
        progressFlushTask?.cancel()
        progressFlushTask = nil
        guard !dirtyProgress.isEmpty else { return }
        let pending = dirtyProgress
        dirtyProgress.removeAll()
        for (itemID, sentenceIndex) in pending {
            guard let idx = items.firstIndex(where: { $0.id == itemID }) else { continue }
            items[idx].currentSentenceIndex = sentenceIndex
        }
        save()
    }

    private func scheduleProgressFlush() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DocumentStore.progressFlushInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushProgress()
        }
    }

    func addBookmark(_ bookmark: Bookmark, to itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].bookmarks.insert(bookmark, at: 0)
        save()
    }

    func removeBookmark(id: UUID, from itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].bookmarks.removeAll { $0.id == id }
        save()
    }

    func delete(_ item: LibraryItem) {
        try? fileManager.removeItem(at: item.fileURL)
        OCRCache.remove(for: item.fileName)
        SentencePageCache.remove(for: item.fileName)
        items.removeAll { $0.id == item.id }
        // Иначе отложенный flushProgress мог бы вписать прогресс уже удалённой
        // книги обратно, если позиция успела прийти до удаления.
        dirtyProgress.removeValue(forKey: item.id)
        save()
    }

    /// Записывает язык книги (результат детекта при первой загрузке либо ручной
    /// выбор пользователя). Пустая строка трактуется как «не определён».
    func setLanguage(_ code: String?, for itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let normalized = (code?.isEmpty ?? true) ? nil : code
        guard items[idx].language != normalized else { return }
        items[idx].language = normalized
        save()
    }

    /// Ручная смена языка книги. В отличие от `setLanguage` (запись результата
    /// детекта) СБРАСЫВАЕТ кэш предложений: язык выбирает профиль, а тот
    /// проставляет `isHeading` и правила разбора — со старым кэшем книга осталась
    /// бы разобранной по-прежнему.
    ///
    /// Побочный эффект переизвлечения: число предложений может слегка измениться
    /// (заголовок отделяется в собственное предложение), поэтому сохранённая
    /// позиция чтения — приблизительная. Ручная правка языка редка, и это дешевле,
    /// чем оставлять книгу разобранной чужим языком.
    func changeLanguage(_ code: String, for itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }),
              items[idx].language != code else { return }
        items[idx].language = code
        SentencePageCache.remove(for: items[idx].fileName)
        OCRCache.remove(for: items[idx].fileName)
        save()
    }

    /// Помечает книгу дочитанной (озвучка дошла до конца) — для фильтра «Законченные».
    func markFinished(_ itemID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }), !items[idx].isFinished else { return }
        items[idx].isFinished = true
        save()
    }

    // MARK: - Коллекции

    @discardableResult
    func createCollection(name: String) -> BookCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let collection = BookCollection(name: trimmed.isEmpty ? "Коллекция" : trimmed)
        collections.append(collection)
        saveCollections()
        return collection
    }

    func deleteCollection(_ collection: BookCollection) {
        collections.removeAll { $0.id == collection.id }
        // Снимаем принадлежность у всех книг, чтобы не осталось «висячих» id.
        for idx in items.indices where items[idx].collectionIDs.contains(collection.id) {
            items[idx].collectionIDs.removeAll { $0 == collection.id }
        }
        saveCollections()
        save()
    }

    func renameCollection(_ collection: BookCollection, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        collections[idx].name = trimmed
        saveCollections()
    }

    /// Добавляет/убирает книгу из коллекции (тумблер принадлежности).
    func setMembership(itemID: UUID, collectionID: UUID, member: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let has = items[idx].collectionIDs.contains(collectionID)
        if member, !has {
            items[idx].collectionIDs.append(collectionID)
        } else if !member, has {
            items[idx].collectionIDs.removeAll { $0 == collectionID }
        } else {
            return
        }
        save()
    }

    /// Число книг в коллекции.
    func bookCount(in collectionID: UUID) -> Int {
        items.reduce(0) { $0 + ($1.collectionIDs.contains(collectionID) ? 1 : 0) }
    }

    // MARK: - Персистентность

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = decoded
        }
    }

    /// Кодирование + запись на диск — off-main (`writeQueue`, сериализация FIFO).
    /// `items` — value type, снимок для фонового потока безопасен.
    private func save() {
        let snapshot = items
        let url = indexURL
        Self.writeQueue.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadCollections() {
        guard let data = try? Data(contentsOf: collectionsURL),
              let decoded = try? JSONDecoder().decode([BookCollection].self, from: data) else { return }
        collections = decoded
    }

    private func saveCollections() {
        guard let data = try? JSONEncoder().encode(collections) else { return }
        try? data.write(to: collectionsURL, options: .atomic)
    }
}
