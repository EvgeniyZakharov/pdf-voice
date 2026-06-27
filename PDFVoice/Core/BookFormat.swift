import Foundation
import UniformTypeIdentifiers

/// Поддерживаемые форматы книг. Источник истины — расширение файла внутри Documents
/// (см. `LibraryItem.format`). Reflowable-форматы рендерятся через ReflowRenderer
/// (TextKit), fixed-layout (`pdf`/`djvu`) — через PDFKit.
enum BookFormat: String, Codable, CaseIterable {
    case pdf, txt, fb2, epub, docx, djvu

    /// Перетекает ли текст под размер экрана/шрифт (TextKit), либо это постраничный
    /// fixed-layout (PDFKit). Развилка слоя отображения в `ReaderViewModel`/`ReaderView`.
    var isReflowable: Bool {
        switch self {
        case .txt, .fb2, .epub, .docx: return true
        case .pdf, .djvu: return false
        }
    }

    /// Человекочитаемая метка для бейджа формата на обложке.
    var badge: String { rawValue.uppercased() }

    /// Определение формата по расширению имени файла. Неизвестное расширение → `.pdf`
    /// (исторический дефолт; старые `library.json` имеют только `uuid.pdf`).
    static func detect(fileName: String) -> BookFormat {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return BookFormat(rawValue: ext) ?? .pdf
    }

    static func detect(url: URL) -> BookFormat {
        detect(fileName: url.lastPathComponent)
    }

    /// UTI-типы для пикера импорта (`.fileImporter`). FB2/DjVu не имеют системных UTI —
    /// заводим их по расширению; неудачное создание просто пропускаем.
    static var importContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .epub]
        for ext in ["docx", "fb2", "djvu"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}