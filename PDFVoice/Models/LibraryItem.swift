import Foundation

struct Bookmark: Codable, Identifiable, Hashable {
    let id: UUID
    let sentenceIndex: Int
    let pageIndex: Int
    let preview: String
    let createdAt: Date

    init(id: UUID = UUID(), sentenceIndex: Int, pageIndex: Int, preview: String, createdAt: Date = Date()) {
        self.id = id
        self.sentenceIndex = sentenceIndex
        self.pageIndex = pageIndex
        self.preview = preview
        self.createdAt = createdAt
    }
}

/// Одна запись в библиотеке. PDF копируется внутрь Documents приложения,
/// в модели храним только относительное имя файла + прогресс чтения.
struct LibraryItem: Codable, Identifiable, Hashable {
    let id: UUID
    /// Имя файла внутри каталога Documents (например "1A2B.pdf").
    var fileName: String
    /// Отображаемое название (по умолчанию — исходное имя файла без расширения).
    var title: String
    var addedDate: Date
    var lastOpened: Date?
    /// Индекс предложения, на котором остановилось чтение (для «продолжить»).
    var currentSentenceIndex: Int
    var bookmarks: [Bookmark]

    init(id: UUID = UUID(),
         fileName: String,
         title: String,
         addedDate: Date = Date(),
         lastOpened: Date? = nil,
         currentSentenceIndex: Int = 0,
         bookmarks: [Bookmark] = []) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.addedDate = addedDate
        self.lastOpened = lastOpened
        self.currentSentenceIndex = currentSentenceIndex
        self.bookmarks = bookmarks
    }

    /// Абсолютный URL файла в каталоге Documents.
    var fileURL: URL {
        DocumentStore.documentsDirectory.appendingPathComponent(fileName)
    }
}
