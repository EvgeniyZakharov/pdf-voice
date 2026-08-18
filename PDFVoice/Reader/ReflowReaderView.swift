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
    /// Предложение, ВЫБРАННОЕ тапом (кандидат на запуск) — бледная подсветка,
    /// независимая от активной; nil = ничего не выбрано.
    var pendingHighlight: Sentence?
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
    /// Размер шрифта основного текста (pt). Меняется на лету из настроек читалки.
    var fontSize: CGFloat = 19
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
    /// Подтверждение «Читать отсюда»: тап пришёлся в зону кнопки play пузырька.
    var onConfirmPlay: () -> Void = {}
    /// Центр кнопки «закладка» в пузырьке (координаты вьюпорта) или nil.
    var bookmarkCenter: CGPoint?
    /// Тап пришёлся в зону кнопки закладки пузырька.
    var onBookmarkHere: () -> Void = {}
    /// Центр видимой кнопки «Вернуться к чтению» (координаты вьюпорта) или nil.
    var returnButtonCenter: CGPoint?
    /// Тап пришёлся в зону кнопки «Вернуться к чтению».
    var onReturnTap: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: UITextInput.closestPosition работает в обоих, но textStorage
        // (addAttribute для подсветки) доступен только в TextKit 1.
        let tv = InsetAwareTextView(usingTextLayoutManager: false)
        tv.isEditable = false
        // isSelectable=true даёт нативное выделение текста по долгому нажатию
        // (лупа + меню «Копировать») — как в PDF. Одиночный тап у нередактируемого
        // текст-вью ничего не выделяет, поэтому наш play-here тап-жест (ниже) с ним
        // не конфликтует: выделение — это long-press, а не tap.
        tv.isSelectable = true
        tv.backgroundColor = theme.pageBackgroundUI
        tv.alwaysBounceVertical = true
        tv.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 48, right: 20)
        tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, fontSize: fontSize, sentences: sentences, chapterOffsets: chapterOffsets)
        context.coordinator.lastTheme = theme
        context.coordinator.lastFontSize = fontSize
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
            tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, fontSize: fontSize, sentences: sentences, chapterOffsets: chapterOffsets)
            context.coordinator.resetHighlightTracking()
        }

        // Смена темы чтения ИЛИ размера шрифта на лету: перекраска/перевёрстка текста.
        // Re-attribute сбрасывает подсветку — обнуляем трекинг, чтобы блок ниже
        // применил её заново нужным цветом.
        if context.coordinator.lastTheme != theme || context.coordinator.lastFontSize != fontSize {
            context.coordinator.lastTheme = theme
            context.coordinator.lastFontSize = fontSize
            tv.backgroundColor = theme.pageBackgroundUI
            tv.attributedText = Coordinator.makeAttributed(text, color: theme.pageTextUI, fontSize: fontSize, sentences: sentences, chapterOffsets: chapterOffsets)
            context.coordinator.resetHighlightTracking()
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
                    // TextKit 1 у больших книг (EPUB-роман) занижает contentSize.height,
                    // пока весь текст не разложен — без форса вёрстки maxY≈minY и прокрутка
                    // к доле схлопывалась в no-op (ползунок «не двигал страницы»).
                    tv.layoutManager.ensureLayout(for: tv.textContainer)
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

        // Бледная подсветка ВЫБРАННОГО тапом предложения — свой трекинг, меняется
        // на тап (не на смену читаемого), поэтому отдельным проходом ВЫШЕ активной.
        if context.coordinator.lastPendingID != pendingHighlight?.id {
            context.coordinator.lastPendingID = pendingHighlight?.id
            context.coordinator.applyPending(pendingHighlight)
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
        /// Трекинг бледной подсветки выбранного тапом предложения.
        var lastPendingID: UUID?
        var lastPendingRange: NSRange?
        /// Последняя применённая тема — для перекраски в updateUIView при смене.
        var lastTheme: ReadingTheme = .sepia
        /// Последний применённый размер шрифта — для перевёрстки при смене.
        var lastFontSize: CGFloat = 19
        /// Активно ли следование вида за текущим предложением.
        var isFollowing = true
        /// Токен последней применённой команды (дедупликация в updateUIView).
        var lastCommandToken: Int = -1
        /// Идёт ли программная анимация возврата к чтению — гасит ложный показ кнопки
        /// возврата на время проезда к подсветке.
        var isReturning = false
        /// Идёт ли анимация автоскролла за подсветкой — чтобы прервать её,
        /// когда пользователь взялся за экран пальцем.
        var isAutoScrolling = false

        /// Последний contentOffset.y, на котором выполнялась логика `reportScroll`
        /// (П4). Дешёвый гейт ДО дорогих вычислений `computeTopChapter`/
        /// `computeHighlightVisible`: микросдвиги на излёте инерции/долях пикселя
        /// не могут заметно поменять ни долю прокрутки, ни главу, ни видимость
        /// подсветки — считать их незачем. Сравнивается с последним РЕПОРТНУТЫМ
        /// (не последним кадра) offset — обновляется ТОЛЬКО когда гейт пройден,
        /// поэтому серия мелких кадров корректно НАКАПЛИВАЕТ сдвиг.
        private var lastGateOffsetY: CGFloat?
        /// Принудительно пропускает гейт на СЛЕДУЮЩИЙ вызов `reportScroll` —
        /// выставляется перед программными переходами/сменой follow-режима, где
        /// смещение contentOffset к моменту вызова может быть уже нулевым (жест
        /// только начался, анимация только что осела), а также в конце драга/
        /// инерции — см. `scrollViewDidEndDragging`/`scrollViewDidEndDecelerating`.
        private var forceNextReport = false
        /// Счётчик кадров скролла с последнего ПРОШЕДШЕГО гейт вычисления —
        /// СТРАХОВКА параллельно с гейтом по смещению (QA нашёл регресс П4: при
        /// реальном свайпе % / номер главы / кнопка возврата переставали
        /// обновляться на всём протяжении жеста). Независимо от того, насколько
        /// надёжен замер смещения по `contentOffset.y` в конкретных условиях
        /// (скорость жеста, частота колбэков во время инерции), лимит на число
        /// ПОДРЯД пропущенных кадров гарантирует прогресс: раз в 2 кадра дорогие
        /// вычисления прогоняются В ЛЮБОМ случае, гейт по смещению остаётся лишь
        /// быстрым путём для явно избыточных кадров.
        private var framesSinceLastCompute = 0
        /// Последний ДОСТАВЛЕННЫЙ наверх снимок — финальный дедуп самого колбэка.
        /// `fraction` хранится как `CGFloat` (естественный тип выражения ниже) —
        /// в `Double` конвертируется только на границе колбэка `onScroll`.
        private var lastReport: (fraction: CGFloat, chapter: Int, visible: Bool, following: Bool)?

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

        /// Одновременное распознавание с pan самого UIScrollView: тап, «ловящий»
        /// декелерацию (пользователь скроллил и тут же тапнул по кнопке возврата
        /// или тексту), иначе проигрывает pan'у и молча пропадает — кнопка
        /// срабатывала через раз.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        /// Ловим тап только в области чтения (между навбаром и панелью). Над баром
        /// и под панелью НЕ ловим — их стеклянные кнопки получают тап сами
        /// (иначе play/pause требовал нескольких нажатий).
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let tv = textView, parent.readingMaxY > parent.readingMinY else { return true }
            let viewportY = touch.location(in: tv).y - tv.contentOffset.y
            return viewportY >= parent.readingMinY && viewportY <= parent.readingMaxY
        }

        static func makeAttributed(_ text: String, color: UIColor, fontSize: CGFloat,
                                   sentences: [Sentence], chapterOffsets: [Int]) -> NSAttributedString {
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 5
            para.paragraphSpacing = 10
            let result = NSMutableAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: color,
                .paragraphStyle: para,
            ])

            // Заголовки — крупнее и жирнее, с отбивкой сверху. Меняем только АТРИБУТЫ
            // на диапазоне (символы те же) → offsets подсветки/навигации не ломаются.
            let headingPara = NSMutableParagraphStyle()
            headingPara.lineSpacing = 3
            headingPara.paragraphSpacing = 8
            headingPara.paragraphSpacingBefore = 18
            let headingFont = UIFont.systemFont(ofSize: fontSize + 5, weight: .bold)
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

        /// Re-attribute сбрасывает ВСЕ фоновые подсветки — обнуляем оба трекинга,
        /// чтобы updateUIView применил и активную, и pending заново нужным цветом.
        func resetHighlightTracking() {
            lastHighlightID = nil
            lastRange = nil
            lastPendingID = nil
            lastPendingRange = nil
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
            // Автоскролл: держим читаемое предложение по центру области чтения.
            // Только при активном следовании (юзер не увёл вид руками).
            if let range, isFollowing { followHighlight(range) }
            reportScroll(tv)
        }

        /// Бледная подсветка выбранного тапом предложения (кандидат на запуск).
        /// Не трогает активную подсветку чтения; если pending совпал бы с активным
        /// диапазоном — пропускаем (активную не перекрываем более бледным цветом).
        func applyPending(_ s: Sentence?) {
            guard let tv = textView else { return }
            let storage = tv.textStorage
            storage.beginEditing()
            if let prev = lastPendingRange {
                storage.removeAttribute(.backgroundColor, range: prev)
                // Если pending перекрывал активную подсветку — вернуть её цвет.
                if let r = lastRange, NSIntersectionRange(prev, r).length > 0 {
                    storage.addAttribute(.backgroundColor, value: parent.theme.highlightUI, range: r)
                }
                lastPendingRange = nil
            }
            if let s, let range = globalRange(for: s), range != lastRange {
                storage.addAttribute(.backgroundColor,
                                     value: parent.theme.pendingHighlightUI,
                                     range: range)
                lastPendingRange = range
            }
            storage.endEditing()
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
            // Полная вёрстка: иначе на больших книгах contentSize.height занижен и
            // клампинг схлопывал прыжок к главе/возврат к чтению в no-op.
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            let minY = -tv.adjustedContentInset.top
            let maxY = max(minY, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
            let clamped = max(minY, min(y, maxY))
            if animated {
                isReturning = true
                UIView.animate(withDuration: 0.3, delay: 0,
                               options: [.curveEaseInOut, .allowUserInteraction]) {
                    tv.contentOffset = CGPoint(x: 0, y: clamped)
                } completion: { [weak self] _ in
                    guard let self, let tv = self.textView else { return }
                    self.isReturning = false
                    // Финальный кадр анимации может двигаться на доли пикселя —
                    // но это «оседание» после isReturning=false обязано дойти
                    // наверх (пересчитанная visible уже не форсирована в true).
                    self.forceNextReport = true
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
            guard let rect = contentRect(forCharRange: range) else { return }
            let visibleCenter = (parent.readingMinY + parent.readingMaxY) / 2
            scroll(toContentY: rect.midY - visibleCenter, animated: animated)
        }

        /// Автоскролл во время озвучки: держит подсвечиваемое предложение по ЦЕНТРУ
        /// области чтения. Вызывается на каждую смену предложения при следовании,
        /// поэтому отличается от `scrollRangeToCenter` двумя вещами:
        ///
        /// 1. **Дозированная вёрстка.** `scroll(toContentY:)` форсит `ensureLayout`
        ///    всего текста — на большой книге это заметный фриз, и платить им за
        ///    КАЖДОЕ предложение нельзя. Раскладываем только до конца предложения
        ///    плюс запас: иначе TextKit занижает `contentSize.height`, клампинг
        ///    срезает цель, и подсветка садится ниже центра.
        /// 2. **Плавность.** Соседнее предложение — короткий проезд с анимацией
        ///    (кадры сливаются в непрерывную прокрутку); далёкий прыжок (skip,
        ///    новая глава) — мгновенно, анимировать пол-книги бессмысленно.
        func followHighlight(_ range: NSRange) {
            guard let tv = textView else { return }
            let ensuredEnd = ensureLayout(around: range)
            guard let rect = contentRect(forCharRange: range) else { return }
            let top = parent.readingMinY
            let bottom = parent.readingMaxY > top ? parent.readingMaxY : tv.bounds.height
            let target: CGFloat
            if rect.height >= bottom - top {
                // Предложение выше области чтения — центрировать нечего:
                // ставим его начало к верху, чтобы читать с первой строки.
                target = rect.minY - top - 12
            } else {
                target = rect.midY - (top + bottom) / 2
            }
            // Нижняя граница прокрутки. `contentSize` у TextKit 1 обновляется
            // ОТЛОЖЕННО (следующим проходом layout), поэтому сразу после
            // ensureLayout он занижен — клампинг по нему сажал подсветку ниже
            // центра (проверено: часть предложений вставала у самой панели).
            // Берём максимум из contentSize и фактического низа разложенного
            // текста: последний символ ensureLayout-диапазона уже имеет геометрию.
            var contentBottom = tv.contentSize.height
            if let tail = contentRect(forCharRange: NSRange(location: ensuredEnd, length: 1)) {
                contentBottom = max(contentBottom, tail.maxY + tv.textContainerInset.bottom)
            }
            let minY = -tv.adjustedContentInset.top
            let maxY = max(minY, contentBottom + tv.adjustedContentInset.bottom - tv.bounds.height)
            let clamped = max(minY, min(target, maxY))
            let delta = abs(clamped - tv.contentOffset.y)
            guard delta > 0.5 else { return }

            let animate = delta < tv.bounds.height * 2 && !UIAccessibility.isReduceMotionEnabled
            guard animate else {
                tv.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                return
            }
            isAutoScrolling = true
            // .allowUserInteraction — иначе на время проезда текст-вью не принимает
            // касания (тап «Отсюда»/кнопки съедаются анимацией).
            // .beginFromCurrentState — предложения могут сменяться чаще, чем
            // заканчивается проезд; новая анимация подхватывает текущую позицию.
            UIView.animate(withDuration: 0.35, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState]) {
                tv.contentOffset = CGPoint(x: 0, y: clamped)
            } completion: { [weak self] _ in
                self?.isAutoScrolling = false
            }
        }

        /// Раскладывает текст до конца диапазона + запас вперёд (несколько экранов),
        /// чтобы под подсветкой было куда прокручивать (см. `followHighlight`).
        /// Возвращает индекс последнего разложенного символа.
        @discardableResult
        private func ensureLayout(around range: NSRange) -> Int {
            guard let tv = textView else { return range.location }
            let total = tv.textStorage.length
            guard total > 0, range.location < total else { return max(0, total - 1) }
            let end = min(total, range.location + range.length + 4000)
            let lm = tv.layoutManager
            lm.ensureLayout(forCharacterRange: NSRange(location: range.location,
                                                       length: end - range.location))
            return end - 1
        }

        /// Ставит символ (начало главы) к верху вьюпорта (для прыжка по оглавлению).
        func scrollCharToTop(_ charIndex: Int, animated: Bool) {
            guard let tv = textView,
                  let rect = contentRect(forCharRange: NSRange(location: charIndex, length: 1))
            else { return }
            scroll(toContentY: rect.minY - tv.textContainerInset.top, animated: animated)
        }

        /// «Видима» ли текущая подсветка: пересекает ли она ЦЕНТРАЛЬНУЮ полосу
        /// области чтения (~60% высоты, отступы по 20% сверху и снизу).
        /// Возвращает true если подсветки нет — кнопка возврата не нужна.
        /// Полоса, а не вся область: кнопка возврата должна появляться, когда
        /// читаемое предложение ушло из центральной части экрана, и прятаться,
        /// когда оно снова примерно по центру — а не когда его краешек ещё
        /// цепляется за самую границу вьюпорта.
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
            // Область чтения [readingMinY…readingMaxY] (между навбаром и панелью)
            // в координатах контейнера, суженная до центральной полосы.
            let top = parent.readingMinY
            let bottom = parent.readingMaxY > top ? parent.readingMaxY : tv.bounds.height
            let band = (bottom - top) * 0.2
            let visibleRect = CGRect(x: 0,
                                     y: tv.contentOffset.y + top + band - inset.top,
                                     width: tv.bounds.width,
                                     height: max(0, (bottom - top) - band * 2))
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
            let offsetY = tv.contentOffset.y
            // Стадия 1 (дешёвая): гейт по смещению — быстрый путь, пропускающий
            // дорогие вычисления, ПОКА накопленный сдвиг с последнего ПРОШЕДШЕГО
            // (не предыдущего кадра!) гейта мал. Плюс страховка по числу подряд
            // пропущенных кадров: даже если по каким-то причинам замер смещения
            // не сработал бы как ожидается, раз в 2 кадра вычисления прогоняются
            // безусловно — гарантирует прогресс, а не «зависание» на весь жест.
            let movedEnough = lastGateOffsetY.map { abs(offsetY - $0) >= 1 } ?? true
            if !forceNextReport && !movedEnough && framesSinceLastCompute < 2 {
                framesSinceLastCompute += 1
                return
            }
            forceNextReport = false
            framesSinceLastCompute = 0
            lastGateOffsetY = offsetY

            let minY = -tv.adjustedContentInset.top
            let maxY = max(minY + 1, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
            let fraction = max(0, min(1, (offsetY - minY) / (maxY - minY)))
            let topChapter = computeTopChapter(tv)
            let visible = isReturning ? true : computeHighlightVisible(tv)
            let isFollowing = self.isFollowing

            // Стадия 2: финальный дедуп самого репорта — доля прокрутки меняется
            // почти на каждый кадр на доли процента, отражать это в @State
            // родителя (и гонять body ReaderScreen) незачем.
            if let last = lastReport,
               abs(fraction - last.fraction) < 0.002,
               topChapter == last.chapter,
               visible == last.visible,
               isFollowing == last.following {
                return
            }
            lastReport = (fraction, topChapter, visible, isFollowing)

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
            // Идущий проезд автоскролла обрываем на текущем кадре, иначе он
            // «тянет» вид против пальца до конца своей анимации.
            if isAutoScrolling {
                isAutoScrolling = false
                let live = scrollView.layer.presentation()?.bounds.origin ?? scrollView.contentOffset
                scrollView.layer.removeAllAnimations()
                scrollView.setContentOffset(live, animated: false)
            }
            // Переход в ручной режим важен сообщить сразу — contentOffset в этот
            // момент мог ещё не сдвинуться ни на пиксель (палец только коснулся),
            // гейт по смещению в reportScroll его бы проглотил.
            forceNextReport = true
            if let tv = scrollView as? UITextView { reportScroll(tv) }
        }

        /// Отпустили палец БЕЗ инерции (короткий/медленный жест) — конечная позиция
        /// уже финальна, но последний кадр мог попасть под гейт по смещению
        /// (QA-регресс П4: остановка ровно на границе гейта не давала финального
        /// пересчёта visible/chapter). Форсим последний репорт явно.
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            forceNextReport = true
            if let tv = scrollView as? UITextView { reportScroll(tv) }
        }

        /// Инерция полностью остановилась — тот же случай, что выше, но для
        /// жеста С инерцией: последний кадр деселерации мог не пройти гейт.
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            forceNextReport = true
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
            // Тап в зоне кнопки play пузырька = подтверждение «Читать отсюда».
            if let center = parent.bubbleCenter,
               hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 28 {
                parent.onConfirmPlay()
                return
            }
            // Тап в зоне кнопки закладки пузырька.
            if let center = parent.bookmarkCenter,
               hypot(viewPoint.x - center.x, viewPoint.y - center.y) <= 28 {
                parent.onBookmarkHere()
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
