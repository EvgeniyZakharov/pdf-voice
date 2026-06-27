import Foundation

/// Источник для `.docx`: zip → `word/document.xml` → текст абзацев (`<w:p>` →
/// конкатенация `<w:t>`). Весь документ — одна глава. Структура глав по стилям
/// заголовков (Heading) — в бэклог.
struct DOCXSource: ReflowSource {
    let url: URL

    func parse() throws -> BookContent {
        let raw = try Data(contentsOf: url)
        guard let zip = ZipArchive(data: raw), let doc = zip.data(for: "word/document.xml") else {
            throw NSError(domain: "DOCX", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать DOCX"])
        }
        let delegate = DocxDelegate()
        let parser = XMLParser(data: doc)
        parser.delegate = delegate
        parser.parse()

        let paras = delegate.paragraphs.filter { !$0.isEmpty }
        guard !paras.isEmpty else {
            throw NSError(domain: "DOCX", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "DOCX без текста"])
        }
        return BookContent(chapters: [BookChapter(title: nil, text: paras.joined(separator: "\n\n"))])
    }
}

private final class DocxDelegate: NSObject, XMLParserDelegate {
    var paragraphs: [String] = []
    private var inText = false
    private var current = ""

    /// XMLParser без namespace-обработки отдаёт имена с префиксом ("w:p", "w:t").
    private func local(_ el: String) -> String {
        el.contains(":") ? String(el.split(separator: ":").last ?? "") : el
    }

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        switch local(el) {
        case "p": current = ""
        case "t": inText = true
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch local(el) {
        case "t": inText = false
        case "p": paragraphs.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
        default: break
        }
    }
}
