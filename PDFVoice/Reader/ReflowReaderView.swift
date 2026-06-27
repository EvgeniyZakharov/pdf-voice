import SwiftUI
import UIKit

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

    private static let fontSize: CGFloat = 19

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.isEditable = false
        tv.isSelectable = false          // тап обрабатываем сами (play-here)
        tv.backgroundColor = Theme.pageBackgroundUI
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 48, right: 20)
        tv.attributedText = Coordinator.makeAttributed(text)

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

        guard let sentence = highlight,
              context.coordinator.lastHighlightID != sentence.id else { return }
        context.coordinator.lastHighlightID = sentence.id
        context.coordinator.applyHighlight(sentence)
    }

    final class Coordinator: NSObject {
        var parent: ReflowReaderView
        weak var textView: UITextView?
        var lastText: String
        var lastHighlightID: UUID?
        var lastRange: NSRange?

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
            if let range { tv.scrollRangeToVisible(range) }
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let tv = textView else { return }
            let point = gesture.location(in: tv)
            let glyphPoint = CGPoint(x: point.x - tv.textContainerInset.left,
                                     y: point.y - tv.textContainerInset.top)
            let charIndex = tv.layoutManager.characterIndex(
                for: glyphPoint, in: tv.textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil)

            for (i, sentence) in parent.sentences.enumerated() {
                if let range = globalRange(for: sentence), NSLocationInRange(charIndex, range) {
                    parent.onTap(i, point)
                    return
                }
            }
            parent.onTap(nil, point)
        }
    }
}
