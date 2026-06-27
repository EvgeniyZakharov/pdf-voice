import Foundation

/// Лёгкое файловое хранилище библиотеки: список — в JSON, сами PDF — в Documents.
/// Сознательно без SwiftData/Core Data, чтобы держать минимальную iOS 16.0.
@MainActor
final class DocumentStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []

    private let indexURL: URL
    private let fileManager = FileManager.default

    nonisolated static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() {
        indexURL = DocumentStore.documentsDirectory.appendingPathComponent("library.json")
        load()
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

    func updateProgress(for itemID: UUID, sentenceIndex: Int) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[idx].currentSentenceIndex = sentenceIndex
        items[idx].lastOpened = Date()
        save()
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
        save()
    }

    // MARK: - Персистентность

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        if let decoded = try? JSONDecoder().decode([LibraryItem].self, from: data) {
            items = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
