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
    var cornerRadius: CGFloat = 6

    @State private var image: UIImage?

    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        Group {
            if let fixedSize {
                content.frame(width: fixedSize.width, height: fixedSize.height)
            } else {
                content.aspectRatio(aspect, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
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
                    .fill(Color(.secondarySystemBackground))
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
        // Рендерим в достаточном разрешении для любой ячейки; масштабируется .fill.
        let px = fixedSize.map { CGSize(width: $0.width * 3, height: $0.height * 3) }
            ?? CGSize(width: 240, height: 348)
        let rendered = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return nil }
            return page.thumbnail(of: px, for: .cropBox)
        }.value
        if let rendered {
            Self.cache.setObject(rendered, forKey: key)
            image = rendered
        }
    }
}
