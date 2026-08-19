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
    /// id коллекций, в которые входит книга (many-to-many).
    var collectionIDs: [UUID]
    /// Книга дочитана до конца (озвучка дошла до последнего предложения) —
    /// для фильтра «Законченные».
    var isFinished: Bool
    /// Язык книги (BCP-47, «ru»/«en») — задаёт языковой профиль и голос озвучки.
    /// `nil` = ещё не определён: детект отрабатывает один раз при первой загрузке
    /// книги и записывает результат сюда. Пока nil — поведение прежнее, русское.
    /// Пользователь может исправить значение вручную (детект иногда ошибается).
    var language: String?
    /// Голос, выбранный ПОЛЬЗОВАТЕЛЕМ для ЭТОЙ книги (пикер в читалке). `nil` —
    /// книга ещё не имеет собственного выбора, эффективный голос берётся из
    /// дефолта Настроек по языку книги (см. `ReaderViewModel.effectiveVoiceSelection`).
    var voiceID: String?

    init(id: UUID = UUID(),
         fileName: String,
         title: String,
         addedDate: Date = Date(),
         lastOpened: Date? = nil,
         currentSentenceIndex: Int = 0,
         bookmarks: [Bookmark] = [],
         collectionIDs: [UUID] = [],
         isFinished: Bool = false,
         language: String? = nil,
         voiceID: String? = nil) {
        self.id = id
        self.fileName = fileName
        self.title = title
        self.addedDate = addedDate
        self.lastOpened = lastOpened
        self.currentSentenceIndex = currentSentenceIndex
        self.bookmarks = bookmarks
        self.collectionIDs = collectionIDs
        self.isFinished = isFinished
        self.language = language
        self.voiceID = voiceID
    }

    // Ручной Decodable: `collectionIDs`/`isFinished`/`language`/`voiceID` добавлены
    // позже — у старых записей `library.json` этих ключей нет. Синтезированный
    // init их бы ТРЕБОВАЛ (дефолты свойств при декодировании не применяются) и
    // ронял загрузку всей библиотеки. `decodeIfPresent` с фолбэком делает
    // миграцию бесшовной.
    enum CodingKeys: String, CodingKey {
        case id, fileName, title, addedDate, lastOpened
        case currentSentenceIndex, bookmarks, collectionIDs, isFinished, language, voiceID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        title = try c.decode(String.self, forKey: .title)
        addedDate = try c.decode(Date.self, forKey: .addedDate)
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened)
        currentSentenceIndex = try c.decode(Int.self, forKey: .currentSentenceIndex)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        collectionIDs = try c.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? []
        isFinished = try c.decodeIfPresent(Bool.self, forKey: .isFinished) ?? false
        language = try c.decodeIfPresent(String.self, forKey: .language)
        voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID)
    }

    /// Абсолютный URL файла в каталоге Documents.
    var fileURL: URL {
        DocumentStore.documentsDirectory.appendingPathComponent(fileName)
    }

    /// Формат книги выводится из расширения `fileName` — единый источник истины,
    /// без миграции `library.json` (старые записи `uuid.pdf` → `.pdf`).
    var format: BookFormat { BookFormat.detect(fileName: fileName) }

    /// Язык для выбора профиля и голоса. ЕДИНСТВЕННОЕ место, где решается, что
    /// делать с `nil` (детект ещё не отработал): читаем как русскую книгу —
    /// прежнее поведение приложения.
    var effectiveLanguage: String { language ?? LanguageProfiles.defaultCode }
}
