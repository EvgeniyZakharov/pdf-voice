import Foundation

/// Пользовательская коллекция (полка) в библиотеке. Хранится отдельным
/// `collections.json`; принадлежность книги коллекции — в `LibraryItem.collectionIDs`
/// (many-to-many: книга может лежать в нескольких коллекциях).
struct BookCollection: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
