import PDFKit
import SwiftUI

/// Обложка книги — первая страница PDF, отрендеренная в миниатюру.
/// Результат кэшируется в памяти по имени файла.
///
/// Два режима:
/// - фиксированный размер (`fixedSize`) — для табличного списка;
/// - гибкий (по умолчанию) — заполняет ширину ячейки с пропорцией `aspect`,
///   чтобы в сетке обложки равномерно делили ширину экрана.
struct BookCoverView: View {
    let fileURL: URL
    let fileName: String
    var fixedSize: CGSize? = nil
    /// Ширина/высота обложки в гибком режиме (книжная страница ≈ 0.7).
    var aspect: CGFloat = 0.69
    var cornerRadius: CGFloat = Theme.radiusCover

    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let fixedSize {
                content.frame(width: fixedSize.width, height: fixedSize.height)
            } else {
                // Пропорцию держит Color.clear (нет собственного «идеального» размера):
                // ширина всегда = ширине ячейки. Если пропорцию задавать самим content,
                // альбомная миниатюра распирает рамку и наезжает на соседние ячейки.
                Color.clear
                    .aspectRatio(aspect, contentMode: .fit)
                    .overlay(content)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Theme.hairline, lineWidth: 0.5)
        )
        .task(id: fileName) { await load() }
    }

    private var content: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Theme.surface)
                    .overlay(
                        Image(systemName: "book.closed")
                            .font(.title)
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    private func load() async {
        let key = fileName as NSString
        if let cached = Self.cache.object(forKey: key) { image = cached; return }
        let url = fileURL
        let format = BookFormat.detect(fileName: fileName)
        // Рендерим в достаточном разрешении для любой ячейки; масштабируется .fill.
        let px = fixedSize.map { CGSize(width: $0.width * 3, height: $0.height * 3) }
            ?? CGSize(width: 240, height: 348)
        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            switch format {
            case .pdf, .djvu:
                guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
                return page.thumbnail(of: px, for: .cropBox)
            case .epub, .fb2:
                // Обложка из контейнера книги; nil (нет обложки) → плейсхолдер.
                return ReflowCover.image(for: url, format: format)
            case .txt, .docx:
                return nil   // текстовые форматы без обложки → плейсхолдер
            }
        }.value
        if let rendered {
            Self.cache.setObject(rendered, forKey: key)
            image = rendered
        }
    }
}
