import Foundation

/// Легаси-кэш OCR (устарел; v2-кэш — SentencePageCache).
/// Оставлен только метод `remove`, который вызывается при удалении документа
/// для зачистки старых файлов кэша первого поколения.
enum OCRCache {

    /// Удаляет файл кэша (при удалении документа из библиотеки).
    static func remove(for fileName: String) {
        try? FileManager.default.removeItem(at: cacheURL(for: fileName))
    }

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
