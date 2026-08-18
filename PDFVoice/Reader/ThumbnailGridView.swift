import PDFKit
import SwiftUI

/// Постраничный листинг: сетка миниатюр всех страниц. Тап → переход.
/// Страницы с index >= readyPageCount ещё не обработаны — показываем плейсхолдер,
/// рендер миниатюры не запрашивается, тап игнорируется.
struct ThumbnailGridView: View {
    let document: PDFDocument
    let currentPage: Int
    let readyPageCount: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var provider: ThumbnailProvider

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    init(document: PDFDocument, currentPage: Int, readyPageCount: Int,
         onSelect: @escaping (Int) -> Void) {
        self.document = document
        self.currentPage = currentPage
        self.readyPageCount = readyPageCount
        self.onSelect = onSelect
        _provider = StateObject(wrappedValue:
            ThumbnailProvider(document: document, size: CGSize(width: 200, height: 280)))
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(0..<document.pageCount, id: \.self) { index in
                            if index < readyPageCount {
                                ThumbnailCell(index: index,
                                              isCurrent: index == currentPage,
                                              provider: provider)
                                    .id(index)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        onSelect(index)
                                        dismiss()
                                    }
                            } else {
                                ThumbnailPlaceholder(index: index)
                                    .id(index)
                            }
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Страницы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

/// Ячейка с миниатюрой одной страницы.
private struct ThumbnailCell: View {
    let index: Int
    let isCurrent: Bool
    let provider: ThumbnailProvider

    @State private var image: UIImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Theme.surface)
                }
            }
            .frame(width: 100, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCover))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCover)
                    .stroke(isCurrent ? Theme.accent : Theme.hairline,
                            lineWidth: isCurrent ? 2 : 0.5)
            }

            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : .secondary)
        }
        .task(id: index) {
            if image == nil { image = await provider.thumbnail(for: index) }
        }
    }
}

/// Ячейка-заглушка для страниц, аудио которых ещё не готово.
private struct ThumbnailPlaceholder: View {
    let index: Int

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Rectangle()
                    .fill(Theme.surface)
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.9)
                    Text("загружается")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 100, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCover))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radiusCover)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            }

            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

/// Поставщик миниатюр: рендер последовательно на фоновой очереди + кэш с
/// вытеснением. Это снимает нагрузку с главного потока (грид листается плавно),
/// не плодит параллельные рендеры PDFKit и не копит миниатюры ВСЕХ пролистанных
/// страниц бесконечно (700-страничная книга раньше держала все разом). Работает
/// на отдельной копии документа, открытой лениво.
@MainActor
final class ThumbnailProvider: ObservableObject {
    /// URL исходного документа — копия для рендера открывается из него ЛЕНИВО
    /// (не синхронно в init на главном потоке, как раньше: `PDFDocument(url:)` —
    /// диск I/O + парсинг, блокирующий вызывающий поток на больших PDF).
    private let documentURL: URL?
    /// Запасной вариант, если у документа нет URL (или его не удалось открыть
    /// повторно) — тот же объект, что показывает читалка.
    private let fallbackDocument: PDFDocument
    private let size: CGSize
    /// Лимит в 120 миниатюр с запасом покрывает экран сетки + прокрутку вперёд/
    /// назад без частых перевытеснений; вытесненные перерендерятся при повторном
    /// скролле — дёшево, рендер и так последовательный на одной очереди.
    private let cache: NSCache<NSNumber, UIImage> = {
        let c = NSCache<NSNumber, UIImage>()
        c.countLimit = 120
        return c
    }()
    private let queue = DispatchQueue(label: "pdfvoice.thumbnails", qos: .utility)
    /// Открытая копия документа — кладётся сюда при первом запросе миниатюры.
    /// `nonisolated(unsafe)`: мутируется и читается ТОЛЬКО изнутри `queue`
    /// (последовательная очередь) — гонок с главным потоком нет, несмотря на то
    /// что сам класс `@MainActor` (изоляция актора нужна `ObservableObject`/
    /// SwiftUI-стороне API, не этому внутреннему состоянию, которое SwiftUI не
    /// видит и никогда не трогает).
    nonisolated(unsafe) private var openedDocument: PDFDocument?

    init(document: PDFDocument, size: CGSize) {
        self.size = size
        self.documentURL = document.documentURL
        self.fallbackDocument = document
    }

    func thumbnail(for index: Int) async -> UIImage? {
        let key = NSNumber(value: index)
        if let cached = cache.object(forKey: key) { return cached }
        let size = self.size
        let url = documentURL
        let fallback = fallbackDocument
        let image: UIImage? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                let doc: PDFDocument
                if let opened = openedDocument {
                    doc = opened
                } else if let url, let copy = PDFDocument(url: url) {
                    doc = copy
                    openedDocument = copy
                } else {
                    doc = fallback
                    openedDocument = fallback
                }
                let img = doc.page(at: index)?.thumbnail(of: size, for: .cropBox)
                continuation.resume(returning: img)
            }
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
