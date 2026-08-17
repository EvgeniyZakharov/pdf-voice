import UIKit

/// Извлечение обложки из reflow-форматов (EPUB/FB2) для показа в библиотеке —
/// по аналогии с PDF-миниатюрой (`BookCoverView`).
///
/// - EPUB: zip → `container.xml` → OPF; обложка = `item properties="cover-image"`
///   (EPUB3) ИЛИ `meta name="cover"` → id манифеста (EPUB2), фолбэк — первое
///   изображение манифеста. Файл распаковывается через уже существующий `ZipArchive`.
/// - FB2: `<coverpage><image l:href="#id"/></coverpage>` → `<binary id="id">base64</binary>`.
///
/// Тяжёлые операции (чтение файла, inflate, base64) — вызывать ВНЕ main-очереди.
enum ReflowCover {

    /// Обложка книги или nil (нет обложки / неподдерживаемый формат) → плейсхолдер.
    static func image(for url: URL, format: BookFormat) -> UIImage? {
        let raw: UIImage?
        switch format {
        case .epub: raw = epubCover(url)
        case .fb2:  raw = fb2Cover(url)
        default:    raw = nil
        }
        return raw.map { downscaled($0) }
    }

    // MARK: - EPUB

    private static func epubCover(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url),
              let zip = ZipArchive(data: data),
              let containerData = zip.data(for: "META-INF/container.xml") else { return nil }
        let container = CoverContainerDelegate()
        runXML(containerData, container)
        guard let opfPath = container.rootfile,
              let opfData = zip.data(for: opfPath) else { return nil }
        let opf = CoverOPFDelegate()
        runXML(opfData, opf)

        // Приоритет: EPUB3 cover-image → EPUB2 meta cover → первое изображение.
        let href = opf.coverImageHref
            ?? opf.metaCoverID.flatMap { opf.manifest[$0] }
            ?? opf.firstImageHref
        guard let href else { return nil }

        let baseDir = (opfPath as NSString).deletingLastPathComponent
        let path = EPUBSource.resolve(base: baseDir, href: href)
        guard let imgData = zip.data(for: path) else { return nil }
        return UIImage(data: imgData)
    }

    // MARK: - FB2

    private static func fb2Cover(_ url: URL) -> UIImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let delegate = FB2CoverDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        guard let b64 = delegate.coverBase64,
              let imgData = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines),
                                 options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: imgData)
    }

    // MARK: - Утилиты

    private static func runXML(_ data: Data, _ delegate: XMLParserDelegate) {
        let p = XMLParser(data: data)
        p.delegate = delegate
        p.parse()
    }

    /// Уменьшает обложку до разумного размера — полноразмерная картинка книги в
    /// NSCache расточительна, а в ячейке всё равно масштабируется под `.fill`.
    private static func downscaled(_ image: UIImage, maxDimension: CGFloat = 700) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension, longest > 0 else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }
}

// MARK: - XMLParser-делегаты обложки

private final class CoverContainerDelegate: NSObject, XMLParserDelegate {
    var rootfile: String?
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        if el.lowercased() == "rootfile", rootfile == nil { rootfile = attr["full-path"] }
    }
}

private final class CoverOPFDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]   // id -> href
    var coverImageHref: String?            // EPUB3: item properties="cover-image"
    var metaCoverID: String?               // EPUB2: meta name="cover" content=id
    var firstImageHref: String?            // фолбэк: первое изображение манифеста

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        switch el.lowercased() {
        case "item":
            guard let id = attr["id"], let href = attr["href"] else { break }
            manifest[id] = href
            let props = attr["properties"]?.lowercased() ?? ""
            if props.contains("cover-image") { coverImageHref = href }
            let media = attr["media-type"]?.lowercased() ?? ""
            if firstImageHref == nil, media.hasPrefix("image/") { firstImageHref = href }
        case "meta":
            // <meta name="cover" content="cover-id"/>
            if attr["name"]?.lowercased() == "cover", let content = attr["content"] {
                metaCoverID = content
            }
        default:
            break
        }
    }
}

private final class FB2CoverDelegate: NSObject, XMLParserDelegate {
    /// base64-содержимое найденного `<binary>` обложки.
    private(set) var coverBase64: String?

    private var coverId: String?          // из <coverpage><image href="#id"/>
    private var inCoverpage = false
    private var capturing = false          // внутри нужного <binary>
    private var buffer = ""

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attr: [String: String]) {
        switch el.lowercased() {
        case "coverpage":
            inCoverpage = true
        case "image":
            if inCoverpage, coverId == nil {
                // Атрибут href в FB2 обычно с namespace-префиксом: l:href или xlink:href.
                let href = attr["l:href"] ?? attr["xlink:href"] ?? attr["href"]
                coverId = href.map { $0.hasPrefix("#") ? String($0.dropFirst()) : $0 }
            }
        case "binary":
            guard coverBase64 == nil,
                  (attr["content-type"]?.lowercased() ?? "").hasPrefix("image/"),
                  let id = attr["id"] else { break }
            // Есть явная обложка → берём ровно её binary; иначе — первое изображение.
            if (coverId == nil) || (id == coverId) {
                capturing = true
                buffer = ""
            }
        default:
            break
        }
    }

    func parser(_ p: XMLParser, foundCharacters string: String) {
        if capturing { buffer += string }
    }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch el.lowercased() {
        case "coverpage":
            inCoverpage = false
        case "binary":
            if capturing {
                coverBase64 = buffer
                capturing = false
                buffer = ""
            }
        default:
            break
        }
    }
}
