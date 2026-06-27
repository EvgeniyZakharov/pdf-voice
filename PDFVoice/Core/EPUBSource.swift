import Foundation

/// Источник для `.epub`: zip → `META-INF/container.xml` → OPF (`spine`/`manifest`)
/// → XHTML-файлы глав в порядке spine → текст. Каждый spine-документ = одна глава;
/// заголовок берётся из первого `<h1..6>`. HTML чистится лёгким стриппером
/// (не `NSAttributedString.html` — он main-thread и медленный).
struct EPUBSource: ReflowSource {
    let url: URL

    func parse() throws -> BookContent {
        let raw = try Data(contentsOf: url)
        guard let zip = ZipArchive(data: raw) else { throw Self.err("Не удалось прочитать EPUB (zip)") }
        guard let containerData = zip.data(for: "META-INF/container.xml") else {
            throw Self.err("EPUB без container.xml")
        }
        let container = ContainerDelegate()
        XMLParser.run(containerData, container)
        guard let opfPath = container.rootfile, let opfData = zip.data(for: opfPath) else {
            throw Self.err("EPUB без OPF")
        }
        let opf = OPFDelegate()
        XMLParser.run(opfData, opf)

        let baseDir = (opfPath as NSString).deletingLastPathComponent
        var chapters: [BookChapter] = []
        for idref in opf.spine {
            guard let href = opf.manifest[idref] else { continue }
            let path = Self.resolve(base: baseDir, href: href)
            guard let html = zip.data(for: path).map({ String(decoding: $0, as: UTF8.self) }) else { continue }
            let extracted = HTMLText.extract(html)
            guard !extracted.text.isEmpty else { continue }
            chapters.append(BookChapter(title: extracted.heading, text: extracted.text))
        }
        guard !chapters.isEmpty else { throw Self.err("EPUB без читаемого текста") }
        return BookContent(chapters: chapters)
    }

    private static func err(_ msg: String) -> Error {
        NSError(domain: "EPUB", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    /// Резолвит href главы относительно каталога OPF, схлопывая `.`/`..` и снимая
    /// percent-encoding и якорь (`#...`).
    static func resolve(base: String, href: String) -> String {
        let noAnchor = href.components(separatedBy: "#").first ?? href
        let decoded = noAnchor.removingPercentEncoding ?? noAnchor
        let parts = base.components(separatedBy: "/") + decoded.components(separatedBy: "/")
        var out: [String] = []
        for p in parts {
            if p.isEmpty || p == "." { continue }
            if p == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(p)
        }
        return out.joined(separator: "/")
    }
}

// MARK: - XMLParser-делегаты EPUB

private extension XMLParser {
    static func run(_ data: Data, _ delegate: XMLParserDelegate) {
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.parse()
    }
}

private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var rootfile: String?
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        if el.lowercased() == "rootfile", rootfile == nil { rootfile = attr["full-path"] }
    }
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]   // id -> href
    var spine: [String] = []               // idref в порядке чтения
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        switch el.lowercased() {
        case "item":
            if let id = attr["id"], let href = attr["href"] { manifest[id] = href }
        case "itemref":
            if let idref = attr["idref"] { spine.append(idref) }
        default: break
        }
    }
}

// MARK: - HTML → текст (лёгкий стриппер)

enum HTMLText {
    /// Возвращает чистый текст (абзацы через "\n\n") и текст первого заголовка.
    static func extract(_ html: String) -> (text: String, heading: String?) {
        var s = html
        s = removeBlock(s, tag: "script")
        s = removeBlock(s, tag: "style")
        s = removeBlock(s, tag: "head")

        let heading = firstHeading(in: s)

        // Блочные закрытия/переносы → разделители абзацев.
        for tag in ["</p>", "</div>", "</h1>", "</h2>", "</h3>", "</h4>", "</h5>", "</h6>",
                    "</li>", "</tr>", "<br>", "<br/>", "<br />"] {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        s = stripTags(s)
        s = decodeEntities(s)

        let lines = s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return (lines.joined(separator: "\n\n"), heading)
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    private static func removeBlock(_ s: String, tag: String) -> String {
        s.replacingOccurrences(of: "<\(tag)[^>]*>.*?</\(tag)>", with: "",
                               options: [.regularExpression, .caseInsensitive])
    }

    private static func firstHeading(in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "<h[1-6][^>]*>(.*?)</h[1-6]>",
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        let inner = ns.substring(with: m.range(at: 1))
        let text = decodeEntities(stripTags(inner)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Декодирует частые именованные и числовые HTML-сущности.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'",
                     "&nbsp;": "\u{00A0}", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
                     "&laquo;": "«", "&raquo;": "»", "&rsquo;": "’", "&lsquo;": "‘",
                     "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        // Числовые: &#1234; и &#x1F600;
        if let re = try? NSRegularExpression(pattern: "&#(x?[0-9a-fA-F]+);") {
            let ns = r as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: r, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let token = ns.substring(with: m.range(at: 1))
                let code: Int? = token.hasPrefix("x") || token.hasPrefix("X")
                    ? Int(token.dropFirst(), radix: 16) : Int(token)
                if let code, let scalar = Unicode.Scalar(code) { result += String(scalar) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            r = result
        }
        return r
    }
}
