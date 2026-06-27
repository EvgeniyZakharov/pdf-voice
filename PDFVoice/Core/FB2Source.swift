import Foundation

/// Источник для `.fb2`: SAX-разбор через `XMLParser`. Главы режутся по `<title>`,
/// текст берётся из `<p>`/`<subtitle>`/`<v>`. Сноски (`<body name="notes">`) и
/// блок `<description>` (метаданные) пропускаются. Кодировку (UTF-8/Windows-1251)
/// определяет сам XMLParser по XML-декларации.
struct FB2Source: ReflowSource {
    let url: URL

    func parse() throws -> BookContent {
        let data = try Data(contentsOf: url)
        let parser = XMLParser(data: data)
        let delegate = FB2Delegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw NSError(domain: "FB2", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Ошибка разбора FB2"])
        }
        return delegate.makeContent()
    }
}

private final class FB2Delegate: NSObject, XMLParserDelegate {
    private var chapters: [(title: String?, paras: [String])] = []
    private var curTitle: String?
    private var curParas: [String] = []
    private var titleParts: [String] = []

    private enum Capture { case none, paragraph, title }
    private var capture: Capture = .none
    private var buffer = ""

    /// Внутри контентного `<body>` (не сносок). FB2 не вкладывает body друг в друга,
    /// поэтому хватает флагов без счётчика глубины.
    private var contentBody = false
    private var notes = false

    func parser(_ parser: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        let name = el.lowercased()
        if name == "body" {
            if attr["name"]?.lowercased() == "notes" { notes = true } else { contentBody = true }
            return
        }
        guard contentBody, !notes else { return }

        switch name {
        case "title":
            flushChapter()
            curTitle = nil
            titleParts = []
            capture = .title
            buffer = ""
        case "p", "subtitle", "v":
            buffer = ""
            if capture != .title { capture = .paragraph }
        case "empty-line":
            if capture == .none { curParas.append("") }
        default:
            break   // inline-теги (emphasis/strong/a…) — текст соберётся через foundCharacters
        }
    }

    func parser(_ parser: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        let name = el.lowercased()
        if name == "body" {
            if notes { notes = false } else { contentBody = false; capture = .none }
            return
        }
        guard contentBody, !notes else { return }

        switch name {
        case "title":
            curTitle = titleParts.joined(separator: " ")
            capture = .none
            buffer = ""
        case "p", "subtitle", "v":
            let text = normalize(buffer)
            if capture == .title {
                if !text.isEmpty { titleParts.append(text) }
            } else if capture == .paragraph {
                if !text.isEmpty { curParas.append(text) }
                capture = .none
            }
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard contentBody, !notes, capture != .none else { return }
        buffer += string
    }

    func parserDidEndDocument(_ parser: XMLParser) { flushChapter() }

    private func flushChapter() {
        guard curTitle != nil || !curParas.isEmpty else { return }
        chapters.append((curTitle, curParas))
        curTitle = nil
        curParas = []
    }

    /// Схлопывает переносы/повторные пробелы из исходного форматирования FB2.
    private func normalize(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func makeContent() -> BookContent {
        let result: [BookChapter] = chapters.map { ch in
            // Заголовок главы — первой строкой текста: он и рендерится, и ловится
            // как isHeading при токенизации. Также сохраняем в BookChapter.title (TOC).
            var blocks = ch.paras
            if let t = ch.title, !t.isEmpty { blocks.insert(t, at: 0) }
            return BookChapter(title: ch.title, text: blocks.joined(separator: "\n\n"))
        }
        return BookContent(chapters: result)
    }
}
