import CoreGraphics
import Foundation

struct SentenceCacheEntry: Codable {
    let schemaVersion: Int?
    let loadedPageCount: Int
    let totalPageCount: Int
    let entries: [EncodedSentence]

    var isComplete: Bool { loadedPageCount >= totalPageCount }
}

struct EncodedSentence: Codable {
    let rawText: String
    let pageIndex: Int
    let rangeLoc: Int?
    let rangeLen: Int?
    let boxes: [[Double]]
    // Опционально: старые кэши без этого поля декодируются как nil -> false.
    let isHeading: Bool?
    let language: String?
    /// Reflow-локатор (UTF-16 смещение в тексте главы). Опционально: старые
    /// (PDF-only) кэши без этого поля декодируются как nil — читаются как раньше,
    /// schemaVersion не поднимаем (M14).
    let charOffset: Int?

    init(_ s: Sentence) {
        rawText    = s.rawText
        pageIndex  = s.pageIndex
        rangeLoc   = s.range?.location
        rangeLen   = s.range?.length
        boxes      = s.boxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        isHeading  = s.isHeading
        language   = s.language
        charOffset = s.charOffset
    }

    func toSentence() -> Sentence {
        let range: NSRange? = rangeLoc.map { NSRange(location: $0, length: rangeLen ?? 0) }
        let cgBoxes = boxes.compactMap { a -> CGRect? in
            guard a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        return Sentence(rawText: rawText, pageIndex: pageIndex, range: range, boxes: cgBoxes,
                        isHeading: isHeading ?? false, language: language ?? "ru",
                        charOffset: charOffset)
    }
}

/// Reflow-сайдкар (TXT/FB2/EPUB/DOCX): плоский текст книги + границы глав, чтобы
/// повторное открытие не парсило файл заново. Хранится рядом с кэшем предложений
/// под тем же префиксом имени. Версионируется отдельно от `SentenceCacheEntry` —
/// формат независим (PDF-кэши сайдкара не имеют).
struct ReflowSidecar: Codable {
    let schemaVersion: Int
    let flatText: String
    let chapterOffsets: [Int]
    let chapterTitles: [String?]
}

enum SentencePageCache {

    private static let currentSchemaVersion = 2
    private static let reflowSidecarSchemaVersion = 1

    static func load(for fileName: String) -> SentenceCacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL(for: fileName)),
              let entry = try? JSONDecoder().decode(SentenceCacheEntry.self, from: data),
              entry.schemaVersion == currentSchemaVersion,
              !entry.entries.isEmpty
        else {
            return nil
        }
        return entry
    }

    static func save(sentences: [Sentence], loadedPageCount: Int, totalPageCount: Int, for fileName: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let entry = SentenceCacheEntry(
            schemaVersion: currentSchemaVersion,
            loadedPageCount: loadedPageCount,
            totalPageCount: totalPageCount,
            entries: sentences.map { EncodedSentence($0) }
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: cacheURL(for: fileName), options: .atomic)
    }

    static func remove(for fileName: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: fileName))
        try? FileManager.default.removeItem(at: reflowSidecarURL(for: fileName))
        OCRCache.remove(for: fileName)
    }

    // MARK: - Reflow-сайдкар

    /// Валидный, если версия совпадает и число заголовков/смещений глав согласовано.
    static func loadReflowSidecar(for fileName: String) -> ReflowSidecar? {
        guard let data = try? Data(contentsOf: reflowSidecarURL(for: fileName)),
              let sidecar = try? JSONDecoder().decode(ReflowSidecar.self, from: data),
              sidecar.schemaVersion == reflowSidecarSchemaVersion,
              !sidecar.chapterTitles.isEmpty,
              sidecar.chapterOffsets.count == sidecar.chapterTitles.count
        else {
            return nil
        }
        return sidecar
    }

    static func saveReflowSidecar(flatText: String, chapterOffsets: [Int],
                                  chapterTitles: [String?], for fileName: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let sidecar = ReflowSidecar(schemaVersion: reflowSidecarSchemaVersion, flatText: flatText,
                                    chapterOffsets: chapterOffsets, chapterTitles: chapterTitles)
        guard let data = try? JSONEncoder().encode(sidecar) else { return }
        try? data.write(to: reflowSidecarURL(for: fileName), options: .atomic)
    }

    private static var cacheDirectory: URL = {
        DocumentStore.documentsDirectory.appendingPathComponent("page-cache")
    }()

    private static func cacheURL(for fileName: String) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        return cacheDirectory.appendingPathComponent("\(name).json")
    }

    private static func reflowSidecarURL(for fileName: String) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        return cacheDirectory.appendingPathComponent("\(name)-reflow.json")
    }
}
