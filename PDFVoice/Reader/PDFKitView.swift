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
    /// Предложение, ВЫБРАННОЕ тапом (кандидат на запуск) — бледная подсветка,
    /// независимая от активной; nil = ничего не выбрано.
    var pendingHighlight: Sentence?
    /// Все предложения — для хит-теста тапа.
    var sentences: [Sentence]
    /// Команда перехода на страницу (от скраббера/миниатюр).
    var pageJump: PageJump?
    /// Тап по странице: индекс попавшего предложения (или nil) и точка тапа.
    var onTap: (Int?, CGPoint) -> Void
    /// Сообщает наверх текущую страницу при прокрутке.
    var onPageChange: (Int) -> Void
    /// Сообщает наверх: видима ли подсветка и активно ли следование.
    /// Вызывается после каждого изменения подсветки и при ручном взаимодействии.
    var onFollowChanged: (Bool, Bool) -> Void = { _, _ in }
    /// При смене токена: проскролл к текущей подсветке и возобновление следования.
    var returnToReadingToken: Int = 0
    /// Границы видимой области чтения (глобальные = координаты вьюшки, PDFView
    /// полноэкранный). Тап-жест ловит только между ними — над баром и под панелью
    /// НЕ ловит, чтобы их стеклянные кнопки получали тап (иначе play/pause
    /// требовал нескольких нажатий).
    var readingMinY: CGFloat = 0
    var readingMaxY: CGFloat = 0
    /// Центр видимого пузырька «Читать отсюда» (в координатах вьюшки) или nil.
    /// Тап по этой зоне обрабатывает сам PDF-жест как подтверждение (`onConfirmPlay`) —
    /// SwiftUI-кнопка поверх representable не получает синтетический/сквозной тап
    /// надёжно, а жест PDFView срабатывает всегда.
    var bubbleCenter: CGPoint?
    /// Подтверждение «Читать отсюда»: тап пришёлся в зону кнопки play пузырька.
    var onConfirmPlay: () -> Void = {}
    /// Центр кнопки «закладка» в пузырьке (координаты вьюшки) или nil.
    var bookmarkCenter: CGPoint?
    /// Тап пришёлся в зону кнопки закладки пузырька.
    var onBookmarkHere: () -> Void = {}
    /// Центр видимой кнопки «Вернуться к чтению» (координаты вьюшки) или nil.
    /// Как и пузырёк, её тап обрабатывает жест PDFView (SwiftUI-кнопка поверх
    /// representable надёжно тап не получает).
    var returnButtonCenter: CGPoint?
    /// Тап пришёлся в зону кнопки «Вернуться к чтению».
    var onReturnTap: () -> Void = {}

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
            view.layoutDocumentView()
            context.coordinator.lastSentenceID = nil
            context.coordinator.lastReadyCount = readyPageCount
        } else if readyPageCount != context.coordinator.lastReadyCount {
            // displayDocument получил новые страницы — сообщаем PDFView перерисовать
            // без сброса позиции прокрутки.
            context.coordinator.lastReadyCount = readyPageCount
            view.layoutDocumentView()
        }
        // layoutDocumentView() выше лишь помечает документ на перекомпоновку —
        // реальные фреймы страниц PDFKit пересчитывает асинхронно, на следующий
        // проход рендер-цикла. Если НИЖЕ в ЭТОМ ЖЕ вызове updateUIView мы делаем
        // go(to:) (восстановление позиции при открытии книги, «Вернуться к
        // чтению», переход по миниатюре) — без принудительного layoutIfNeeded()
        // он опирается на ещё не обновлённые фреймы страниц и «уезжает в
        // пустоту» (типичный симптом: открыли книгу на сохранённой позиции
        // дальше первой страницы — вид остался на стр. 1). Вызов дешёвый —
        // no-op, если ничего не помечено грязным.
        view.layoutIfNeeded()

        // Возврат к чтению: кнопка возврата или «Читать отсюда» (приоритет выше pageJump).
        if returnToReadingToken != context.coordinator.lastReturnToken {
            context.coordinator.lastReturnToken = returnToReadingToken
            if let sentence = highlight, let page = document.page(at: sentence.pageIndex) {
                if let range = sentence.range, let selection = page.selection(for: range) {
                    view.go(to: selection)
                } else if !sentence.boxes.isEmpty {
                    var union = CGRect.null
                    for box in sentence.boxes { union = union.union(box) }
                    if !union.isNull { view.go(to: union, on: page) }
                }
                // «Вернуться к чтению» ставит подсветку по центру области чтения.
                context.coordinator.alignHighlightToReadingArea()
                // Индекс страницы сообщаем НАПРЯМУЮ (не полагаясь на KVO-скролл):
                // go(to:) может сработать до того, как PDFView пересчитает layout,
                // и reportVisiblePage() в этот момент вернёт устаревшую страницу.
                context.coordinator.reportPage(sentence.pageIndex)
            }
            context.coordinator.isFollowing = true
            context.coordinator.reportFollowChanged()
        }

        // Команда перехода на страницу (скраббер/миниатюры) → browse-режим.
        if let jump = pageJump,
           jump.token != context.coordinator.lastJumpToken,
           let page = document.page(at: jump.page) {
            context.coordinator.lastJumpToken = jump.token
            view.go(to: page)
            context.coordinator.isFollowing = false
            // Явный репорт, не полагаясь на KVO: тап по миниатюре у родителя
            // (ReaderView.requestJump) уже двигает currentPage напрямую, но тот
            // путь может быть проглочен гонкой с закрытием листа миниатюр
            // (dismiss + мутация состояния в одном действии) — этот вызов
            // независим от того листа и всегда доставляет индекс.
            context.coordinator.reportPage(jump.page)
            context.coordinator.reportFollowChanged()
        }

        // Подсветка ВЫБРАННОГО тапом предложения — бледными аннотациями, независимо
        // от активной подсветки чтения. Меняется на тап (не на смену читаемого),
        // поэтому свой проход со своим трекингом, ВЫШЕ guard'а reading-подсветки.
        if context.coordinator.lastPendingID != pendingHighlight?.id {
            context.coordinator.lastPendingID = pendingHighlight?.id
            context.coordinator.applyPendingHighlight(pendingHighlight)
        }

        // Подсветку перестраиваем только при смене предложения (не на каждое слово).
        guard let sentence = highlight,
              context.coordinator.lastSentenceID != sentence.id,
              let page = document.page(at: sentence.pageIndex) else { return }
        context.coordinator.lastSentenceID = sentence.id
        context.coordinator.clearOCRHighlight()

        // Пока идёт следование, счётчик страниц обязан отражать РЕАЛЬНУЮ
        // читаемую страницу сразу, а не ждать реактивный KVO-скролл: при
        // восстановлении позиции (после переоткрытия книги) go(to:) ниже
        // может выполниться раньше, чем PDFView пересчитает layout, и
        // reportVisiblePage() в этот момент вернёт страницу 0.
        if context.coordinator.isFollowing {
            context.coordinator.reportPage(sentence.pageIndex)
        }

        if let range = sentence.range, let selection = page.selection(for: range) {
            // Текстовый слой — нативная подсветка выделением.
            selection.color = Theme.pdfHighlightUI
            view.highlightedSelections = [selection]
            // Авто-прокрутка только при активном следовании: держим читаемое
            // предложение по центру области чтения (не под стеклянной панелью).
            if context.coordinator.isFollowing {
                context.coordinator.followHighlight()
                // При самом первом updateUIView (сразу после makeUIView) SwiftUI
                // ещё не выдал PDFView реальный размер — view.bounds нулевые, и
                // прокрутка выше уезжает в никуда. Второго прохода подсветки для
                // ЭТОГО ЖЕ предложения не будет (lastSentenceID уже проставлен
                // выше), поэтому без явного повтора вид так и останется на
                // стр. 1 при открытии книги на сохранённой позиции.
                if view.bounds.isEmpty { context.coordinator.scheduleFollowScrollRetry() }
            }
        } else if !sentence.boxes.isEmpty {
            // OCR — подсветка аннотациями по боксам строк.
            view.highlightedSelections = nil
            var union = CGRect.null
            for box in sentence.boxes {
                let annotation = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
                annotation.color = Theme.pdfHighlightUI
                page.addAnnotation(annotation)
                context.coordinator.ocrAnnotations.append((page, annotation))
                union = union.union(box)
            }
            if !union.isNull, context.coordinator.isFollowing {
                context.coordinator.followHighlight()
                // См. комментарий в ветке текстового слоя выше: первый проход
                // с нулевыми bounds — прокрутка без эффекта, повтора не будет.
                if view.bounds.isEmpty { context.coordinator.scheduleFollowScrollRetry() }
            }
        } else {
            view.highlightedSelections = nil
        }

        // Уведомляем родителя о состоянии следования после применения подсветки.
        context.coordinator.reportFollowChanged()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFKitView
        weak var pdfView: PDFView?
        var lastSentenceID: UUID?
        var lastJumpToken: Int = -1
        var lastReadyCount: Int = 0
        /// Текущие подсветки-аннотации для OCR-страниц (чтобы снять при смене предложения).
        var ocrAnnotations: [(PDFPage, PDFAnnotation)] = []
        /// Бледные аннотации подсветки ВЫБРАННОГО тапом предложения (снимаются при смене выбора).
        var pendingAnnotations: [(PDFPage, PDFAnnotation)] = []
        /// id последнего выбранного предложения (дедуп прохода pending-подсветки).
        var lastPendingID: UUID?
        /// Активно ли следование вида за текущим предложением.
        var isFollowing = true
        /// Идёт ли анимация автоскролла за подсветкой — чтобы оборвать её,
        /// когда пользователь взялся за экран пальцем.
        var isAutoScrolling = false
        /// Токен последнего выполненного returnToReading (дедупликация).
        var lastReturnToken: Int = 0

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
                [weak self] _, _ in
                self?.reportVisiblePage()
                // Живой пересчёт видимости подсветки при КАЖДОМ тике скролла
                // (как reflow в scrollViewDidScroll): раньше кнопка возврата
                // пересчитывалась только в начале следующего жеста — вернул вид
                // к тексту руками, а кнопка оставалась висеть. Дедуп внутри.
                self?.reportFollowChanged()
            }
            // Детект ручного взаимодействия (pan/pinch) для паузы следования.
            // Надёжнее, чем переопределять делегат PDFView (внутренний делегат PDFKit).
            scrollView.panGestureRecognizer.addTarget(self, action: #selector(userInteracted(_:)))
            scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(userInteracted(_:)))
        }

        /// «Видима» ли текущая подсветка: пересекает ли она ЦЕНТРАЛЬНУЮ полосу
        /// области чтения (~60% высоты, отступы по 20% сверху и снизу).
        /// Полоса, а не вся область: кнопка возврата должна появляться, когда
        /// читаемое предложение ушло из центральной части экрана, и прятаться,
        /// когда оно снова примерно по центру — а не когда его краешек ещё
        /// цепляется за самую границу.
        /// Возвращает true если подсветки нет — кнопку возврата показывать не надо.
        func computeHighlightVisible() -> Bool {
            guard let pdfView, let sentence = parent.highlight else { return true }
            guard let page = parent.document.page(at: sentence.pageIndex) else { return true }
            let reading = parent.readingMaxY > parent.readingMinY
                ? CGRect(x: 0, y: parent.readingMinY, width: pdfView.bounds.width,
                         height: parent.readingMaxY - parent.readingMinY)
                : pdfView.bounds
            let band = reading.insetBy(dx: 0, dy: reading.height * 0.2)
            if let range = sentence.range, let selection = page.selection(for: range) {
                let boundsInView = pdfView.convert(selection.bounds(for: page), from: page)
                return band.intersects(boundsInView)
            } else if !sentence.boxes.isEmpty {
                for box in sentence.boxes {
                    let boxInView = pdfView.convert(box, from: page)
                    if band.intersects(boxInView) { return true }
                }
                return false
            }
            return true
        }

        /// Прямоугольник текущей подсветки в координатах PDFView (или nil).
        private func highlightRectInView() -> CGRect? {
            guard let pdfView, let sentence = parent.highlight,
                  let page = parent.document.page(at: sentence.pageIndex) else { return nil }
            if let range = sentence.range, let selection = page.selection(for: range) {
                return pdfView.convert(selection.bounds(for: page), from: page)
            }
            guard !sentence.boxes.isEmpty else { return nil }
            var union = CGRect.null
            for box in sentence.boxes { union = union.union(box) }
            return union.isNull ? nil : pdfView.convert(union, from: page)
        }

        /// Смещение вида, при котором подсветка встаёт по ЦЕНТРУ области чтения.
        /// Область чтения — между стеклянным баром и панелью плеера: PDFView про
        /// них не знает (контент течёт под них через ignoresSafeArea) и своим
        /// центром считает середину всего экрана.
        private func centerDelta(for rect: CGRect) -> CGFloat {
            let margin: CGFloat = 16
            let minY = parent.readingMinY + margin
            let maxY = parent.readingMaxY - margin
            // Предложение выше области чтения — центрировать нечего: верх к верху,
            // чтобы читать с первой строки.
            if rect.height >= maxY - minY { return rect.minY - minY }
            return rect.midY - (minY + maxY) / 2
        }

        /// Доводит скролл после `go(to:)` до центра области чтения: сам PDFView
        /// может остановиться так, что подсветка «видима» для него, но фактически
        /// под стеклом бара или панели.
        func alignHighlightToReadingArea() {
            guard parent.readingMaxY > parent.readingMinY,
                  let rect = highlightRectInView() else { return }
            scrollBy(centerDelta(for: rect), animated: false)
        }

        /// Автоскролл за озвучкой: держит читаемое предложение по центру области
        /// чтения. Короткий проезд (соседнее предложение — в пределах пары
        /// экранов) идёт плавной анимацией, кадры сливаются в непрерывную
        /// прокрутку; далёкий прыжок (skip, другая страница) — мгновенным `go(to:)`
        /// PDFKit: анимировать пролёт через полкниги бессмысленно, да и координаты
        /// далёкой страницы надёжнее получить уже после перехода.
        func followHighlight() {
            guard let pdfView else { return }
            if parent.readingMaxY > parent.readingMinY, !pdfView.bounds.isEmpty,
               let rect = highlightRectInView() {
                let delta = centerDelta(for: rect)
                if abs(delta) <= pdfView.bounds.height * 2 {
                    scrollBy(delta, animated: !UIAccessibility.isReduceMotionEnabled)
                    return
                }
            }
            scrollToCurrentHighlight()
        }

        /// Сдвигает вид на `delta` точек с клампингом по границам контента.
        private func scrollBy(_ delta: CGFloat, animated: Bool) {
            guard abs(delta) > 0.5, let pdfView,
                  let scrollView = Coordinator.firstScrollView(in: pdfView) else { return }
            var offset = scrollView.contentOffset
            let lo = -scrollView.adjustedContentInset.top
            let hi = max(lo, scrollView.contentSize.height
                             + scrollView.adjustedContentInset.bottom
                             - scrollView.bounds.height)
            offset.y = min(max(offset.y + delta, lo), hi)
            guard abs(offset.y - scrollView.contentOffset.y) > 0.5 else { return }
            guard animated else {
                scrollView.setContentOffset(offset, animated: false)
                return
            }
            isAutoScrolling = true
            // .allowUserInteraction — иначе на время проезда вид не принимает
            // касания (тап «Отсюда» и кнопки съедаются анимацией).
            // .beginFromCurrentState — короткие предложения сменяются чаще, чем
            // заканчивается проезд; новая анимация подхватывает текущую позицию.
            UIView.animate(withDuration: 0.35, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                scrollView.contentOffset = offset
            } completion: { [weak self] _ in
                self?.isAutoScrolling = false
            }
        }

        /// Повторяет follow-скролл к текущей подсветке, когда PDFView реально
        /// получит размер. При самом первом updateUIView (сразу после makeUIView)
        /// SwiftUI ещё не выдал вью frame — bounds нулевые, и go(to:) в основном
        /// проходе не может вычислить осмысленный scroll offset. Повтора «само
        /// собой» не будет: lastSentenceID уже проставлен для этого предложения,
        /// а highlight не меняется, пока не начнётся озвучка следующего —
        /// поэтому опрашиваем bounds на каждом тике до 10 раз (обычно хватает
        /// одного-двух после первого layout pass) и, как только они появились,
        /// прокручиваем ещё раз к актуальной подсветке.
        func scheduleFollowScrollRetry(attempt: Int = 0) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isFollowing, let pdfView = self.pdfView else { return }
                guard !pdfView.bounds.isEmpty else {
                    if attempt < 10 { self.scheduleFollowScrollRetry(attempt: attempt + 1) }
                    return
                }
                pdfView.layoutIfNeeded()
                self.scrollToCurrentHighlight()
            }
        }

        /// Прокручивает к текущей подсветке (highlight из parent) и репортит её
        /// страницу — вынесено из основного прохода updateUIView, чтобы
        /// scheduleFollowScrollRetry могло вызвать это же действие повторно, когда
        /// PDFView наконец получит реальный размер.
        func scrollToCurrentHighlight() {
            guard let pdfView, let sentence = parent.highlight,
                  let page = parent.document.page(at: sentence.pageIndex) else { return }
            if let range = sentence.range, let selection = page.selection(for: range) {
                pdfView.go(to: selection)
            } else if !sentence.boxes.isEmpty {
                var union = CGRect.null
                for box in sentence.boxes { union = union.union(box) }
                if !union.isNull { pdfView.go(to: union, on: page) }
            }
            alignHighlightToReadingArea()
            reportPage(sentence.pageIndex)
        }

        /// Последняя отправленная пара (видимость, следование) — дедуп для
        /// вызовов с каждого тика скролла.
        private var lastReportedFollow: (vis: Bool, following: Bool)?

        func reportFollowChanged() {
            let vis = computeHighlightVisible()
            let following = isFollowing
            guard lastReportedFollow?.vis != vis
                || lastReportedFollow?.following != following else { return }
            lastReportedFollow = (vis, following)
            // Вычисления синхронные, но КОЛБЭК — за пределами прохода updateUIView:
            // мутация @State родителя внутри рендера SwiftUI молча выбрасывается
            // («Modifying state during view update») — из-за этого кнопка возврата
            // не скрывалась после программного скролла. Тот же паттерн, что в
            // ReflowReaderView.reportScroll.
            let callback = parent.onFollowChanged
            DispatchQueue.main.async {
                callback(vis, following)
            }
        }

        /// Срабатывает при начале pan или pinch — пользователь вручную скроллит/зумирует.
        @objc func userInteracted(_ gesture: UIGestureRecognizer) {
            guard gesture.state == .began else { return }
            isFollowing = false
            // Идущий проезд автоскролла обрываем на текущем кадре, иначе он
            // «тянет» вид против пальца до конца своей анимации.
            if isAutoScrolling, let pdfView,
               let scrollView = Coordinator.firstScrollView(in: pdfView) {
                isAutoScrolling = false
                let live = scrollView.layer.presentation()?.bounds.origin ?? scrollView.contentOffset
                scrollView.layer.removeAllAnimations()
                scrollView.setContentOffset(live, animated: false)
            }
            reportFollowChanged()
        }

        /// Определяет страницу по центру вьюпорта и сообщает наверх (с дедупом).
        /// KVO-наблюдатель contentOffset может сработать СИНХРОННО из updateUIView
        /// (программный go(to:) внутри рендера SwiftUI меняет contentOffset сразу) —
        /// делегируем в deliverPageChange, а не мутируем @State родителя тут же.
        private func reportVisiblePage() {
            guard let pdfView else { return }
            let center = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            guard let page = pdfView.page(for: center, nearest: true) else { return }
            let index = parent.document.index(for: page)
            guard index != NSNotFound else { return }
            deliverPageChange(index)
        }

        /// Сообщает наверх страницу НАПРЯМУЮ (без чтения layout PDFView) — вызывается
        /// при программных переходах (восстановление позиции, «Вернуться к чтению»,
        /// переход по миниатюре), где geometry ещё может быть не пересчитана в
        /// момент go(to:).
        func reportPage(_ index: Int) {
            deliverPageChange(index)
        }

        /// Общая доставка индекса страницы наверх — за пределами прохода
        /// updateUIView (тот же паттерн, что в reportFollowChanged): мутация @State
        /// родителя СИНХРОННО во время рендера SwiftUI молча отбрасывается
        /// («Modifying state during view update») — из-за этого счётчик страниц не
        /// обновлялся ни после восстановления позиции, ни после «Вернуться к
        /// чтению», ни из KVO, сработавшего синхронно от программного go(to:).
        ///
        /// lastReportedPage обновляем ТОЛЬКО вместе с фактической доставкой
        /// колбэка (внутри async-блока), а не сразу в вызывающем коде — иначе
        /// дедуп рассинхронизируется с реальностью: если бы индекс отмечался
        /// «отправленным» сразу, а сама доставка потом молча терялась, повторный
        /// репорт того же индекса больше никогда бы не прошёл guard. Повторная
        /// проверка внутри async также защищает от гонки МЕЖДУ источниками
        /// (программный переход и синхронно сработавший KVO-скролл, либо два
        /// программных перехода подряд) — устаревший запланированный индекс
        /// отбрасываем, а не затираем им уже доставленный более свежий.
        private func deliverPageChange(_ index: Int) {
            guard index != lastReportedPage else { return }
            let callback = parent.onPageChange
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lastReportedPage != index else { return }
                self.lastReportedPage = index
                callback(index)
            }
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

        /// Бледная подсветка выбранного тапом предложения. Аннотациями (а не
        /// `highlightedSelections`, который занят активной подсветкой чтения) —
        /// оба слоя живут независимо. Строки берём из выделения текстового слоя,
        /// иначе — из OCR-боксов.
        func applyPendingHighlight(_ sentence: Sentence?) {
            for (page, annotation) in pendingAnnotations {
                page.removeAnnotation(annotation)
            }
            pendingAnnotations.removeAll()
            guard let sentence,
                  let page = parent.document.page(at: sentence.pageIndex) else { return }
            let addBox: (CGRect) -> Void = { box in
                guard !box.isNull, box.width > 0, box.height > 0 else { return }
                let ann = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
                ann.color = Theme.pdfPendingHighlightUI
                page.addAnnotation(ann)
                self.pendingAnnotations.append((page, ann))
            }
            if let range = sentence.range, let selection = page.selection(for: range) {
                for line in selection.selectionsByLine() { addBox(line.bounds(for: page)) }
            } else {
                for box in sentence.boxes { addBox(box) }
            }
        }

        @objc func pageChanged(_ note: Notification) {
            // Резервный путь: KVO-скролл обычно опережает эту нотификацию,
            // но при программном go(to:) она может прийти первой.
            reportVisiblePage()
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let pdfView else { return }
            let location = gesture.location(in: pdfView)
            // Тап в зоне кнопки play пузырька = подтверждение «Читать отсюда».
            if let center = parent.bubbleCenter,
               hypot(location.x - center.x, location.y - center.y) <= 28 {
                parent.onConfirmPlay()
                return
            }
            // Тап в зоне кнопки закладки пузырька.
            if let center = parent.bookmarkCenter,
               hypot(location.x - center.x, location.y - center.y) <= 28 {
                parent.onBookmarkHere()
                return
            }
            // Тап в зоне кнопки «Вернуться к чтению».
            if let rc = parent.returnButtonCenter,
               hypot(location.x - rc.x, location.y - rc.y) <= 30 {
                parent.onReturnTap()
                return
            }
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

        /// Ловим тап только в области чтения (между навбаром и панелью). Над баром
        /// и под панелью НЕ ловим — их стеклянные кнопки получают тап сами.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool {
            guard let pdfView, parent.readingMaxY > parent.readingMinY else { return true }
            let y = touch.location(in: pdfView).y
            return y >= parent.readingMinY && y <= parent.readingMaxY
        }
    }
}
