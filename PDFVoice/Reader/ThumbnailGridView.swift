import PDFKit
import SwiftUI

/// Постраничный листинг: сетка миниатюр всех страниц. Тап → переход.
struct ThumbnailGridView: View {
    let document: PDFDocument
    let currentPage: Int
    let onSelect: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var provider: ThumbnailProvider

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 16)]

    init(document: PDFDocument, currentPage: Int, onSelect: @escaping (Int) -> Void) {
        self.document = document
        self.currentPage = currentPage
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
                            ThumbnailCell(index: index,
                                          isCurrent: index == currentPage,
                                          provider: provider)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onSelect(index)
                                    dismiss()
                                }
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(currentPage, anchor: .center) }
            }
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
                    Rectangle().fill(Color(.secondarySystemBackground))
                }
            }
            .frame(width: 100, height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrent ? Color.accentColor : Color(.separator),
                            lineWidth: isCurrent ? 2.5 : 0.5)
            }

            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .task(id: index) {
            if image == nil { image = await provider.thumbnail(for: index) }
        }
    }
}

/// Поставщик миниатюр: рендер последовательно на фоновой очереди + кэш.
/// Это снимает нагрузку с главного потока (грид листается плавно) и не плодит
/// параллельные рендеры PDFKit. Работает на отдельной копии документа.
@MainActor
final class ThumbnailProvider: ObservableObject {
    private let document: PDFDocument?
    private let size: CGSize
    private var cache: [Int: UIImage] = [:]
    private let queue = DispatchQueue(label: "pdfvoice.thumbnails", qos: .utility)

    init(document: PDFDocument, size: CGSize) {
        self.size = size
        if let url = document.documentURL, let copy = PDFDocument(url: url) {
            self.document = copy          // отдельная копия — без гонки с PDFView читалки
        } else {
            self.document = document      // запасной вариант
        }
    }

    func thumbnail(for index: Int) async -> UIImage? {
        if let cached = cache[index] { return cached }
        guard let document else { return nil }
        let size = self.size
        let image: UIImage? = await withCheckedContinuation { continuation in
            queue.async {
                let img = document.page(at: index)?.thumbnail(of: size, for: .cropBox)
                continuation.resume(returning: img)
            }
        }
        if let image { cache[index] = image }
        return image
    }
}
