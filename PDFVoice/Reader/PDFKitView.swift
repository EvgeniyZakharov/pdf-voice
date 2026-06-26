import PDFKit
import SwiftUI
import UIKit

/// Команда перехода на страницу. `token` делает каждую команду уникальной,
/// чтобы повторный переход на ту же страницу тоже срабатывал.
struct PageJump: Equatable {
    let page: Int
    let token: Int
}

/// SwiftUI-обёртка над PDFView: показывает документ, подсвечивает текущее
/// предложение, прокручивает к нему, сообщает о тапе по предложению и о смене
/// страницы, а также выполняет команды перехода (скраббер/миниатюры).
struct PDFKitView: UIViewRepresentable {
    let document: PDFDocument
    /// Число готовых страниц в displayDocument (совпадает с document.pageCount,
    /// но передаётся явно, чтобы updateUIView мог отреагировать на рост).
    var readyPageCount: Int
    /// Текущее озвучиваемое предложение (для подсветки и авто-прокрутки).
    var highlight: Sentence?
    /// Все предложения — для хит-теста тапа.
    var sentences: [Sentence]
    /// Команда перехода на страницу (от скраббера/миниатюр).
    var pageJump: PageJump?
    /// Тап по странице: индекс попавшего предложения (или nil) и точка тапа.
    var onTap: (Int?, CGPoint) -> Void
    /// Сообщает наверх текущую страницу при прокрутке.
    var onPageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.backgroundColor = Theme.pageBackgroundUI
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.usePageViewController(false)

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view)

        context.coordinator.pdfView = view
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        // Подписка на скролл для реактивного индикатора страницы (см. attach…).
        context.coordinator.attachScrollTrackingIfNeeded()

        if view.document !== document {
            view.document = document
            context.coordinator.lastSentenceID = nil
            context.coordinator.lastReadyCount = readyPageCount
        } else if readyPageCount != context.coordinator.lastReadyCount {
            // displayDocument получил новые страницы — сообщаем PDFView перерисовать
            // без сброса позиции прокрутки.
            context.coordinator.lastReadyCount = readyPageCount
            view.layoutDocumentView()
        }

        // Команда перехода на страницу (скраббер/миниатюры) — приоритетнее подсветки.
        if let jump = pageJump,
           jump.token != context.coordinator.lastJumpToken,
           let page = document.page(at: jump.page) {
            context.coordinator.lastJumpToken = jump.token
            view.go(to: page)
        }

        // Подсветку перестраиваем только при смене предложения (не на каждое слово).
        guard let sentence = highlight,
              context.coordinator.lastSentenceID != sentence.id,
              let page = document.page(at: sentence.pageIndex) else { return }
        context.coordinator.lastSentenceID = sentence.id
        context.coordinator.clearOCRHighlight()

        if let range = sentence.range, let selection = page.selection(for: range) {
            // Текстовый слой — нативная подсветка выделением.
            selection.color = UIColor.systemYellow.withAlphaComponent(0.45)
            view.highlightedSelections = [selection]
            view.go(to: selection)
        } else if !sentence.boxes.isEmpty {
            // OCR — подсветка аннотациями по боксам строк.
            view.highlightedSelections = nil
            var union = CGRect.null
            for box in sentence.boxes {
                let annotation = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
                page.addAnnotation(annotation)
                context.coordinator.ocrAnnotations.append((page, annotation))
                union = union.union(box)
            }
            if !union.isNull { view.go(to: union, on: page) }
        } else {
            view.highlightedSelections = nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        var lastSentenceID: UUID?
        var lastJumpToken: Int = -1
        var lastReadyCount: Int = 0
        /// Текущие подсветки-аннотации для OCR-страниц (чтобы снять при смене предложения).
        var ocrAnnotations: [(PDFPage, PDFAnnotation)] = []

        /// KVO-наблюдение за contentOffset внутреннего scroll view PDFView.
        private var scrollObservation: NSKeyValueObservation?
        /// Последняя отправленная наверх страница — чтобы не дёргать @State зря.
        private var lastReportedPage: Int = -1

        init(_ parent: PDFKitView) { self.parent = parent }

        deinit {
            NotificationCenter.default.removeObserver(self)
            scrollObservation?.invalidate()
        }

        /// Реактивное отслеживание скролла. `.PDFViewPageChanged` срабатывает
        /// дискретно и с запозданием (только при «переключении» текущей страницы),
        /// из-за чего ползунок и номер отставали. Наблюдаем contentOffset напрямую
        /// и на каждый кадр скролла вычисляем страницу по центру вьюпорта.
        func attachScrollTrackingIfNeeded() {
            guard scrollObservation == nil,
                  let pdfView,
                  let scrollView = Coordinator.firstScrollView(in: pdfView) else { return }
            scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) {
                [weak self] _, _ in self?.reportVisiblePage()
            }
        }

        /// Определяет страницу по центру вьюпорта и сообщает наверх (с дедупом).
        private func reportVisiblePage() {
            guard let pdfView else { return }
            let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: center, nearest: true) else { return }
            let index = parent.document.index(for: page)
            guard index != NSNotFound, index != lastReportedPage else { return }
            lastReportedPage = index
            parent.onPageChange(index)
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            for sub in view.subviews {
                if let sv = sub as? UIScrollView { return sv }
                if let found = firstScrollView(in: sub) { return found }
            }
            return nil
        }

        func clearOCRHighlight() {
            for (page, annotation) in ocrAnnotations {
                page.removeAnnotation(annotation)
            }
            ocrAnnotations.removeAll()
        }

        @objc func pageChanged(_ note: Notification) {
            // Резервный путь: KVO-скролл обычно опережает эту нотификацию,
            // но при программном go(to:) она может прийти первой.
            reportVisiblePage()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView else { return }
            let location = gesture.location(in: pdfView)
            guard let page = pdfView.page(for: location, nearest: true) else {
                parent.onTap(nil, location)
                return
            }
            let pageIndex = parent.document.index(for: page)
            let pagePoint = pdfView.convert(location, to: page)

            for (i, sentence) in parent.sentences.enumerated() where sentence.pageIndex == pageIndex {
                if let range = sentence.range, let selection = page.selection(for: range) {
                    for line in selection.selectionsByLine() where line.bounds(for: page).contains(pagePoint) {
                        parent.onTap(i, location)
                        return
                    }
                } else if sentence.boxes.contains(where: { $0.contains(pagePoint) }) {
                    parent.onTap(i, location)
                    return
                }
            }
            parent.onTap(nil, location)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
