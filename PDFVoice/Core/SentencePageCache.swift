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

    init(_ s: Sentence) {
        rawText   = s.rawText
        pageIndex = s.pageIndex
        rangeLoc  = s.range?.location
        rangeLen  = s.range?.length
        boxes     = s.boxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        isHeading = s.isHeading
        language  = s.language
    }

    func toSentence() -> Sentence {
        let range: NSRange? = rangeLoc.map { NSRange(location: $0, length: rangeLen ?? 0) }
        let cgBoxes = boxes.compactMap { a -> CGRect? in
            guard a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        return Sentence(rawText: rawText, pageIndex: pageIndex, range: range, boxes: cgBoxes,
                        isHeading: isHeading ?? false, language: language ?? "ru")
    }
}

enum SentencePageCache {

    private static let currentSchemaVersion = 2

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
        OCRCache.remove(for: fileName)
    }

    private static var cacheDirectory: URL = {
        DocumentStore.documentsDirectory.appendingPathComponent("page-cache")
    }()

    private static func cacheURL(for fileName: String) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        return cacheDirectory.appendingPathComponent("\(name).json")
    }
}
