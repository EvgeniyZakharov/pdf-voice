import SwiftUI
import UIKit

/// Тегированная команда для управления скроллом reflow-вьюшки из родителя.
/// `.scrollToFraction` — прокрутить к доле книги (browse); `.returnToReading` — вернуться
/// к текущей подсветке и возобновить следование.
enum ReflowCommand: Equatable {
    case scrollToFraction(Double, token: Int)
    case returnToReading(token: Int)
    case scrollToChapter(Int, token: Int)
}

/// SwiftUI-обёртка над `UITextView` для reflow-форматов (TXT/FB2/EPUB/DOCX):
/// рендерит плоский текст книги, подсвечивает текущее предложение фоном по
/// символьному диапазону, прокручивает к нему и сообщает о тапе по предложению.
///
/// Аналог `PDFKitView` для перетекающего текста. Маппинг предложение → диапазон:
/// `chapterOffsets[sentence.pageIndex] + sentence.charOffset`, длина = UTF-16
/// длина `rawText` (он вербатим-срез текста главы).
struct ReflowReaderView: UIViewRepresentable {
    /// Плоский текст книги (результат `BookContent.flatten().text`).
    let text: String
    /// Глобальные смещения начала глав (тот же `flatten().chapterOffsets`).
    let chapterOffsets: [Int]
    /// Текущее озвучиваемое предложение (подсветка + авто-прокрутка).
    var highlight: Sentence?
    /// Все предложения — для хит-теста тапа.
    var sentences: [Sentence]
    /// Тап: индекс попавшего предложения (или nil) и точка тапа.
    var onTap: (Int?, CGPoint) -> Void
    /// Репорт позиции скролла: fraction (0…1), topChapter, highlightVisible, isFollowing.
    /// Вызывается при каждом изменении позиции и после применения подсветки.
    var onScroll: (Double, Int, Bool, Bool) -> Void = { _, _, _, _ in }
    /// Тегированная команда от родителя; применяется в updateUIView при смене токена.
    var command: ReflowCommand? = nil
    /// Тема страницы (фон + текст + подсветка). Применяется на лету в updateUIView.
    var theme: ReadingTheme = .sepia
    /// Сколько места снизу (от края экрана) должно оставаться свободным от текста
    /// при прокрутке в конец: высота плавающей стеклянной панели плеера + зазор.
    /// Сам текст-вью растянут под панель (ignoresSafeArea) — текст уходит под стекло
    /// и размывается им, а не обрезается жёсткой кромкой.
    var bottomClearance: CGFloat = 0
    /// Верх видимой области чтения (глобальные координаты = координаты вьюпорта,
    /// т.к. текст-вью полноэкранный): низ навбара. Текст течёт под стеклянный бар,
    /// но центрирование/старт учитывают этот инсет, а тап-жест над баром не ловит.
    var readingMinY: CGFloat = 0
    /// Низ видимой области чтения: верх плавающей панели плеера. Тап-жест под
    /// панелью не ловит (её кнопки получают тап).
    var readingMaxY: CGFloat = 0
    /// Центр видимого пузырька «Читать отсюда» (координаты вьюпорта) или nil.
    /// Тап по этой зоне обрабатывает сам жест текста как подтверждение.
    var bubbleCenter: CGPoint?
    /// Подтверждение «Читать отсюда»: тап пришёлся в зону пузырька.
    var onConfirmPlay: () -> Void = {}
    /// Центр видимой кнопки «Вернуться к чтению» (координаты вьюпорта) или nil.
    var returnButtonCenter: CGPoint?
    /// Тап пришёлся в зону кнопки «Вернуться к чтению».
    var onReturnTap: () -> Void = {}

    private static let fontSize: CGFloat = 19

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: UITextInput.closestPosition работает в обоих, но textStorage
        // (addAttribute для подсветки) доступен только в TextKit 1.
        let tv = InsetAwareTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false          // тап обрабатываем сами (play-here)
        tv.backgroundColor = theme.pageBackgroundUI
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 48, right: 20)
        tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, sentences: sentences, chapterOffsets: chapterOffsets)
        context.coordinator.lastTheme = theme
        // Coordinator становится делегатом скролла для детекта ручного взаимодействия.
        tv.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        tv.addGestureRecognizer(tap)
        context.coordinator.textView = tv
        // Safe area приходит после встраивания в окно — пересчитываем инсет тогда.
        tv.onSafeAreaChange = { [weak coordinator = context.coordinator] in
            coordinator?.updateInsets()
        }
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateInsets()

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, sentences: sentences, chapterOffsets: chapterOffsets)
            context.coordinator.lastHighlightID = nil
            context.coordinator.lastRange = nil
        }

        // Смена темы чтения на лету: фон + перекраска текста. Re-attribute сбрасывает
        // подсветку — обнуляем трекинг, чтобы блок ниже применил её заново нужным цветом.
        if context.coordinator.lastTheme != theme {
            context.coordinator.lastTheme = theme
            tv.backgroundColor = theme.pageBackgroundUI
            tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, sentences: sentences, chapterOffsets: chapterOffsets)
            context.coordinator.lastHighlightID = nil
            context.coordinator.lastRange = nil
        }

        // Команда от родителя (слайдер или кнопка возврата). Применяем при смене токена.
        if let cmd = command {
            let token: Int
            switch cmd {
            case .scrollToFraction(_, let t): token = t
            case .returnToReading(let t): token = t
            case .scrollToChapter(_, let t): token = t
            }
            if token != context.coordinator.lastCommandToken {
                context.coordinator.lastCommandToken = token
                switch cmd {
                case .scrollToFraction(let f, _):
                    let minY = -tv.adjustedContentInset.top
                    let maxY = max(minY, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
                    tv.setContentOffset(CGPoint(x: 0, y: minY + f * (maxY - minY)), animated: false)
                    context.coordinator.isFollowing = false
                    context.coordinator.reportScroll(tv)
                case .returnToReading:
                    // Центрируем подсветку и едем к ней плавно за 0.3 c (не прыжок).
                    context.coordinator.isFollowing = true
                    if let range = context.coordinator.lastRange {
                        context.coordinator.scrollRangeToCenter(range, animated: true)
                    } else {
                        context.coordinator.reportScroll(tv)
                    }
                case .scrollToChapter(let ch, _):
                    // Переход позиции чтения: вид следует за новой подсветкой,
                    // play/pause сохраняется методом seekToChapter.
                    context.coordinator.isFollowing = true
                    let offsets = chapterOffsets
                    if offsets.indices.contains(ch) {
                        context.coordinator.scrollCharToTop(offsets[ch], animated: false)
                    }
                    context.coordinator.reportScroll(tv)
                }
            }
        }

        guard let sentence = highlight,
              context.coordinator.lastHighlightID != sentence.id else { return }
        context.coordinator.lastHighlightID = sentence.id
        context.coordinator.applyHighlight(sentence)
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReflowReaderView
        weak var textView: UITextView?
        var lastText: String
        var lastHighlightID: UUID?
        var lastRange: NSRange?
        /// Последняя применённая тема — для перекраски в updateUIView при смене.
        var lastTheme: ReadingTheme = .sepia
        /// Активно ли следование вида за текущим предложением.
        var isFollowing = true
        /// Токен последней применённой команды (дедупликация в updateUIView).
        var lastCommandToken: Int = -1
        /// Идёт ли программная анимация возврата к чтению — гасит ложный показ кнопки
        /// возврата на время проезда к подсветке.
        var isReturning = false

        init(_ parent: ReflowReaderView) {
            self.parent = parent
            self.lastText = parent.text
        }

        /// Инсеты прокрутки: сверху — под навбар (первая строка на старте видна
        /// ниже бара, но при прокрутке текст течёт под стекло), снизу — под
        /// плавающую панель, чтобы конец книги дочитывался над ней.
        func updateInsets() {
            guard let tv = textView else { return }
            let top = parent.readingMinY
            let bottom = max(0, parent.bottomClearance - tv.safeAreaInsets.bottom)
            if abs(tv.contentInset.top - top) > 0.5 { tv.contentInset.top = top }
            if abs(tv.contentInset.bottom - bottom) > 0.5 { tv.contentInset.bottom = bottom }
        }

        /// Ловим тап только в области чтения (между навбаром и панелью). Над баром
        /// и под панелью НЕ ловим — их стеклянные кнопки получают тап сами
        /// (иначе play/pause требовал нескольких нажатий).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tv = textView, parent.readingMaxY > parent.readingMinY else { return true }
            let viewportY = touch.location(in: tv).y - tv.contentOffset.y
            return viewportY >= parent.readingMinY && viewportY <= parent.readingMaxY
        }

        static func makeAttributed(_ text: String, color: UIColor,
                                   sentences: [Sentence], chapterOffsets: [Int]) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 5
            para.paragraphSpacing = 10
            let result = NSMutableAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: ReflowReaderView.fontSize),
                .foregroundColor: color,
                .paragraphStyle: para,
            ])

            // Заголовки — крупнее и жирнее, с отбивкой сверху. Меняем только АТРИБУТЫ
            // на диапазоне (символы те же) → offsets подсветки/навигации не ломаются.
            let headingPara = NSMutableParagraphStyle()
            headingPara.lineSpacing = 3
            headingPara.paragraphSpacing = 8
            headingPara.paragraphSpacingBefore = 18
            let headingFont = UIFont.systemFont(ofSize: ReflowReaderView.fontSize + 5, weight: .bold)
            let total = (text as NSString).length
            for s in sentences where s.isHeading {
                guard chapterOffsets.indices.contains(s.pageIndex) else { continue }
                let base = chapterOffsets[s.pageIndex] + (s.charOffset ?? 0)
                let len = (s.rawText as NSString).length
                guard base >= 0, len > 0, base + len <= total else { continue }
                let range = NSRange(location: base, length: len)
                result.addAttribute(.font, value: headingFont, range: range)
                result.addAttribute(.paragraphStyle, value: headingPara, range: range)
            }
            return result
        }

        /// Глобальный UTF-16 диапазон предложения в плоском тексте книги.
        func globalRange(for s: Sentence) -> NSRange? {
            guard parent.chapterOffsets.indices.contains(s.pageIndex) else { return nil }
            let base = parent.chapterOffsets[s.pageIndex] + (s.charOffset ?? 0)
            let len = (s.rawText as NSString).length
            let total = (parent.text as NSString).length
            guard base >= 0, len > 0, base + len <= total else { return nil }
            return NSRange(location: base, length: len)
        }

        func applyHighlight(_ s: Sentence) {
            guard let tv = textView else { return }
            let storage = tv.textStorage
            storage.beginEditing()
            if let prev = lastRange {
                storage.removeAttribute(.backgroundColor, range: prev)
            }
            let range = globalRange(for: s)
            if let range {
                storage.addAttribute(.backgroundColor,
                                     value: parent.theme.highlightUI,
                                     range: range)
            }
            lastRange = range
            storage.endEditing()
            // Скроллим к подсветке только при активном следовании.
            if let range, isFollowing { tv.scrollRangeToVisible(range) }
            reportScroll(tv)
        }

        // MARK: - Программная прокрутка (возврат к чтению / прыжок к главе)

        /// Прямоугольник символьного диапазона в координатах контента (с инсетами).
        private func contentRect(forCharRange range: NSRange) -> CGRect? {
            guard let tv = textView else { return nil }
            let total = tv.textStorage.length
            guard range.location >= 0, range.location < total else { return nil }
            let clamped = NSRange(location: range.location,
                                  length: min(max(range.length, 1), total - range.location))
            let lm = tv.layoutManager
            let glyphRange = lm.glyphRange(forCharacterRange: clamped, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            rect.origin.y += tv.textContainerInset.top
            rect.origin.x += tv.textContainerInset.left
            return rect
        }

        /// Прокрутка к заданному y контента. Анимация — ровно 0.3 c (не «прыжок»);
        /// на время анимации isReturning гасит кнопку возврата.
        private func scroll(toContentY y: CGFloat, animated: Bool) {
            guard let tv = textView else { return }
            let minY = -tv.adjustedContentInset.top
            let maxY = max(minY, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
            let clamped = max(minY, min(y, maxY))
            if animated {
                isReturning = true
                UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseInOut]) {
                    tv.contentOffset = CGPoint(x: 0, y: clamped)
                } completion: { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    self.isReturning = false
                    self.reportScroll(tv)
                }
            } else {
                tv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
            }
        }

        /// Центрирует диапазон в ВИДИМОЙ области чтения [readingMinY…readingMaxY]
        /// (между навбаром и панелью). Без их учёта подсветка уезжала к верхнему
        /// краю (центр брался по всей высоте bounds).
        func scrollRangeToCenter(_ range: NSRange, animated: Bool) {
            guard let tv = textView, let rect = contentRect(forCharRange: range) else { return }
            let visibleCenter = (parent.readingMinY + parent.readingMaxY) / 2
            scroll(toContentY: rect.midY - visibleCenter, animated: animated)
        }

        /// Ставит символ (начало главы) к верху вьюпорта (для прыжка по оглавлению).
        func scrollCharToTop(_ charIndex: Int, animated: Bool) {
            guard let tv = textView,
                  let rect = contentRect(forCharRange: NSRange(location: charIndex, length: 1))
            else { return }
            scroll(toContentY: rect.minY - tv.textContainerInset.top, animated: animated)
        }

        /// Видима ли область текущей подсветки во вьюпорте.
        /// Возвращает true если подсветки нет — кнопка возврата не нужна.
        ///
        /// Считаем через ВИДИМЫЙ символьный диапазон: раскладываем только видимую
        /// область (дёшево) и проверяем пересечение с диапазоном подсветки. Прежняя
        /// версия звала `boundingRect(forGlyphRange:)` на ДАЛЁКОМ диапазоне подсветки —
        /// это форсировало вёрстку всего текста выше неё на КАЖДЫЙ тик скролла, из-за
        /// чего ползунок тормозил на больших книгах.
        func computeHighlightVisible(_ tv: UITextView) -> Bool {
            guard let range = lastRange else { return true }
            let lm = tv.layoutManager
            let inset = tv.textContainerInset
            // Видимая область чтения [readingMinY…readingMaxY] (между навбаром и
            // панелью) в координатах контейнера: зоны за стеклянными баром/панелью
            // не считаются видимыми (текст там размыт стеклом).
            let top = parent.readingMinY
            let bottom = parent.readingMaxY > top ? parent.readingMaxY : tv.bounds.height
            let visibleRect = CGRect(x: 0,
                                     y: tv.contentOffset.y + top - inset.top,
                                     width: tv.bounds.width,
                                     height: max(0, bottom - top))
            let visGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: tv.textContainer)
            let visChars = lm.characterRange(forGlyphRange: visGlyphs, actualGlyphRange: nil)
            return NSIntersectionRange(visChars, range).length > 0
        }

        /// Индекс главы у верха вьюпорта (последний chapterOffset ≤ charIndex вверху).
        func computeTopChapter(_ tv: UITextView) -> Int {
            let inset = tv.textContainerInset
            // «Верх вьюпорта» — ниже прозрачного навбара (adjustedContentInset.top),
            // текст теперь тянется и под него.
            let point = CGPoint(x: inset.left + 1,
                                y: tv.contentOffset.y + tv.adjustedContentInset.top + 1)
            guard let pos = tv.closestPosition(to: point) else { return 0 }
            let charIndex = tv.offset(from: tv.beginningOfDocument, to: pos)
            let offsets = parent.chapterOffsets
            var ch = 0
            for (i, offset) in offsets.enumerated() {
                if offset <= charIndex { ch = i } else { break }
            }
            return ch
        }

        func reportScroll(_ tv: UITextView) {
            let minY = -tv.adjustedContentInset.top
            let maxY = max(minY + 1, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
            let fraction = max(0, min(1, (tv.contentOffset.y - minY) / (maxY - minY)))
            let topChapter = computeTopChapter(tv)
            let visible = isReturning ? true : computeHighlightVisible(tv)
            let isFollowing = self.isFollowing
            // Захват onScroll по значению (struct-замыкание): вычисления сделаны
            // синхронно, но ВЫЗОВ колбэка выносим за проход updateUIView — иначе
            // мутация @State родителя внутри рендера даёт «undefined behavior».
            let callback = parent.onScroll
            DispatchQueue.main.async {
                callback(fraction, topChapter, visible, isFollowing)
            }
        }

        // MARK: - UIScrollViewDelegate (через UITextViewDelegate)

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // Ручной скролл → выходим из режима следования.
            isFollowing = false
            if let tv = scrollView as? UITextView { reportScroll(tv) }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // НЕ меняем isFollowing: срабатывает и при программном скролле
            // (scrollRangeToVisible из applyHighlight).
            if let tv = scrollView as? UITextView { reportScroll(tv) }
        }

        // MARK: - Тап

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = textView else { return }
            // point — в координатах контента (с учётом прокрутки).
            let point = gesture.location(in: tv)
            // viewPoint — в координатах вьюпорта, нужен для позиционирования пузырька
            // «Читать отсюда»: без вычитания offset пузырёк уедет за экран при прокрутке.
            let viewPoint = CGPoint(x: point.x - tv.contentOffset.x,
                                    y: point.y - tv.contentOffset.y)
            // Тап в зоне видимого пузырька = подтверждение «Читать отсюда».
            if let center = parent.bubbleCenter,
               hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 32 {
                parent.onConfirmPlay()
                return
            }
            // Тап в зоне кнопки «Вернуться к чтению».
            if let rc = parent.returnButtonCenter,
               hypot(viewPoint.x - rc.x, viewPoint.y - rc.y) <= 30 {
                parent.onReturnTap()
                return
            }
            // UITextInput учитывает textContainerInset сам — передаём point как есть.
            guard let pos = tv.closestPosition(to: point) else {
                parent.onTap(nil, viewPoint); return
            }
            let charIndex = tv.offset(from: tv.beginningOfDocument, to: pos)

            // Привязка к БЛИЖАЙШЕМУ предложению, а не строгое попадание: между абзацами
            // и главами есть разделители/переносы (flatten склеивает через «\n\n»), и тап
            // часто попадает в такой зазор. Строгая проверка NSLocationInRange там давала
            // промах → пузырёк не показывался. Выбираем предложение с минимальной
            // дистанцией от charIndex до его диапазона (0 = точное попадание).
            var bestIndex: Int?
            var bestDistance = Int.max
            for (i, sentence) in parent.sentences.enumerated() {
                guard let range = globalRange(for: sentence) else { continue }
                let distance: Int
                if NSLocationInRange(charIndex, range) {
                    distance = 0
                } else if charIndex < range.location {
                    distance = range.location - charIndex
                } else {
                    distance = charIndex - (range.location + range.length - 1)
                }
                if distance < bestDistance {
                    bestDistance = distance
                    bestIndex = i
                    if distance == 0 { break }
                }
            }
            parent.onTap(bestIndex, viewPoint)
        }
    }
}

/// UITextView с колбэком на смену safe area: нижний inset прокрутки зависит от
/// высоты home-индикатора, которая известна только после встраивания в окно.
final class InsetAwareTextView: UITextView {
    var onSafeAreaChange: (() -> Void)?

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onSafeAreaChange?()
    }
}
