import CoreGraphics
import Foundation

struct SentenceCacheEntry: Codable {
    let loadedPageCount: Int
    let totalPageCount: Int
    let entries: [EncodedSentence]

    var isComplete: Bool { loadedPageCount >= totalPageCount }
}

struct EncodedSentence: Codable {
    let text: String
    let pageIndex: Int
    let rangeLoc: Int?
    let rangeLen: Int?
    let boxes: [[Double]]
    // Опционально: старые кэши без этого поля декодируются как nil -> false.
    let isHeading: Bool?

    init(_ s: Sentence) {
        text      = s.text
        pageIndex = s.pageIndex
        rangeLoc  = s.range?.location
        rangeLen  = s.range?.length
        boxes     = s.boxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        isHeading = s.isHeading
    }

    func toSentence() -> Sentence {
        let range: NSRange? = rangeLoc.map { NSRange(location: $0, length: rangeLen ?? 0) }
        let cgBoxes = boxes.compactMap { a -> CGRect? in
            guard a.count == 4 else { return nil }
            return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
        }
        return Sentence(text: text, pageIndex: pageIndex, range: range, boxes: cgBoxes,
                        isHeading: isHeading ?? false)
    }
}

enum SentencePageCache {

    static func load(for fileName: String) -> SentenceCacheEntry? {
        guard let data = try? Data(contentsOf: cacheURL(for: fileName)),
              let entry = try? JSONDecoder().decode(SentenceCacheEntry.self, from: data),
              !entry.entries.isEmpty
        else {
            if let sentences = OCRCache.load(for: fileName) {
                let encoded = sentences.map { EncodedSentence($0) }
                return SentenceCacheEntry(loadedPageCount: Int.max, totalPageCount: 0, entries: encoded)
            }
            return nil
        }
        return entry
    }

    static func save(sentences: [Sentence], loadedPageCount: Int, totalPageCount: Int, for fileName: String) {
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let entry = SentenceCacheEntry(
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
