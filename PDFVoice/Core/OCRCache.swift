import CoreGraphics
import Foundation

/// Кеш результатов OCR: после первого распознавания сохраняет предложения
/// в JSON-файл рядом с PDF. Повторное открытие — мгновенно, без Vision.
enum OCRCache {

    // MARK: - Кодируемая обёртка над Sentence

    /// Sentence содержит NSRange и CGRect, которые не Codable «из коробки» —
    /// используем плоское представление с примитивами.
    private struct Entry: Codable {
        let text: String
        let pageIndex: Int
        // NSRange (nil для OCR-страниц, там подсветка через boxes)
        let rangeLoc: Int?
        let rangeLen: Int?
        // CGRect массив [x, y, w, h] на каждый бокс строки
        let boxes: [[Double]]

        init(_ s: Sentence) {
            text      = s.text
            pageIndex = s.pageIndex
            rangeLoc  = s.range?.location
            rangeLen  = s.range?.length
            boxes     = s.boxes.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] }
        }

        func toSentence() -> Sentence {
            let range: NSRange? = rangeLoc.map { NSRange(location: $0, length: rangeLen ?? 0) }
            let cgBoxes = boxes.compactMap { a -> CGRect? in
                guard a.count == 4 else { return nil }
                return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
            }
            return Sentence(text: text, pageIndex: pageIndex, range: range, boxes: cgBoxes)
        }
    }

    // MARK: - Публичный API

    /// Сохраняет предложения на диск. Вызывается после успешного OCR.
    static func save(_ sentences: [Sentence], for fileName: String) {
        let entries = sentences.map { Entry($0) }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: cacheURL(for: fileName), options: .atomic)
    }

    /// Загружает кеш если он существует. nil — кеша нет, нужен OCR.
    static func load(for fileName: String) -> [Sentence]? {
        let url = cacheURL(for: fileName)
        guard let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data),
              !entries.isEmpty
        else { return nil }
        return entries.map { $0.toSentence() }
    }

    /// Удаляет кеш (при удалении документа из библиотеки).
    static func remove(for fileName: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: fileName))
    }

    // MARK: - Вспомогательное

    private static var cacheDirectory: URL = {
        let dir = DocumentStore.documentsDirectory.appendingPathComponent("ocr-cache")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cacheURL(for fileName: String) -> URL {
        let name = (fileName as NSString).deletingPathExtension
        return cacheDirectory.appendingPathComponent("\(name).json")
    }
}
