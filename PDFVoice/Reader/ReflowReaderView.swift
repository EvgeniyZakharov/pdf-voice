import SwiftUI
import UIKit

/// Тегированная команда для управления скроллом reflow-вьюшки из родителя.
/// `.scrollToFraction` — прокрутить к доле книги (browse); `.returnToReading` — вернуться
/// к текущей подсветке и возобновить следование.
enum ReflowCommand: Equatable {
    case scrollToFraction(Double, token: Int)
    case returnToReading(token: Int)
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

    private static let fontSize: CGFloat = 19

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: UITextInput.closestPosition работает в обоих, но textStorage
        // (addAttribute для подсветки) доступен только в TextKit 1.
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = false          // тап обрабатываем сами (play-here)
        tv.backgroundColor = Theme.pageBackgroundUI
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 48, right: 20)
        tv.attributedText = Coordinator.makeAttributed(text)
        // Coordinator становится делегатом скролла для детекта ручного взаимодействия.
        tv.delegate = context.coordinator

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tv.addGestureRecognizer(tap)
        context.coordinator.textView = tv
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        context.coordinator.parent = self

        if context.coordinator.lastText != text {
            context.coordinator.lastText = text
            tv.attributedText = Coordinator.makeAttributed(text)
            context.coordinator.lastHighlightID = nil
            context.coordinator.lastRange = nil
        }

        // Команда от родителя (слайдер или кнопка возврата). Применяем при смене токена.
        if let cmd = command {
            let token: Int
            switch cmd {
            case .scrollToFraction(_, let t): token = t
            case .returnToReading(let t): token = t
            }
            if token != context.coordinator.lastCommandToken {
                context.coordinator.lastCommandToken = token
                switch cmd {
                case .scrollToFraction(let f, _):
                    let maxY = max(0, tv.contentSize.height - tv.bounds.height)
                    tv.setContentOffset(CGPoint(x: 0, y: f * maxY), animated: false)
                    context.coordinator.isFollowing = false
                    context.coordinator.reportScroll(tv)
                case .returnToReading:
                    if let range = context.coordinator.lastRange {
                        tv.scrollRangeToVisible(range)
                    }
                    context.coordinator.isFollowing = true
                    context.coordinator.reportScroll(tv)
                }
            }
        }

        guard let sentence = highlight,
              context.coordinator.lastHighlightID != sentence.id else { return }
        context.coordinator.lastHighlightID = sentence.id
        context.coordinator.applyHighlight(sentence)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ReflowReaderView
        weak var textView: UITextView?
        var lastText: String
        var lastHighlightID: UUID?
        var lastRange: NSRange?
        /// Активно ли следование вида за текущим предложением.
        var isFollowing = true
        /// Токен последней применённой команды (дедупликация в updateUIView).
        var lastCommandToken: Int = -1

        init(_ parent: ReflowReaderView) {
            self.parent = parent
            self.lastText = parent.text
        }

        static func makeAttributed(_ text: String) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 5
            para.paragraphSpacing = 10
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: ReflowReaderView.fontSize),
                .foregroundColor: UIColor.label,
                .paragraphStyle: para,
            ])
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
                                     value: UIColor.systemYellow.withAlphaComponent(0.4),
                                     range: range)
            }
            lastRange = range
            storage.endEditing()
            // Скроллим к подсветке только при активном следовании.
            if let range, isFollowing { tv.scrollRangeToVisible(range) }
            reportScroll(tv)
        }

        /// Видима ли область текущей подсветки во вьюпорте (координаты контента).
        /// Возвращает true если подсветки нет — кнопка возврата не нужна.
        func computeHighlightVisible(_ tv: UITextView) -> Bool {
            guard let range = lastRange else { return true }
            let lm = tv.layoutManager
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: tv.textContainer)
            // Конвертируем из координат text-container в координаты контента.
            rect.origin.y += tv.textContainerInset.top
            rect.origin.x += tv.textContainerInset.left
            let visible = CGRect(x: 0, y: tv.contentOffset.y,
                                 width: tv.bounds.width, height: tv.bounds.height)
            return visible.intersects(rect)
        }

        /// Индекс главы у верха вьюпорта (последний chapterOffset ≤ charIndex вверху).
        func computeTopChapter(_ tv: UITextView) -> Int {
            let inset = tv.textContainerInset
            let point = CGPoint(x: inset.left + 1, y: tv.contentOffset.y + inset.top + 1)
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
            let maxY = max(1.0, tv.contentSize.height - tv.bounds.height)
            let fraction = max(0, min(1, tv.contentOffset.y / maxY))
            let topChapter = computeTopChapter(tv)
            let visible = computeHighlightVisible(tv)
            parent.onScroll(fraction, topChapter, visible, isFollowing)
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
