# R17 — Разделить «позицию чтения» и «позицию просмотра» (follow-режим + кнопка возврата)

Спроектировано по скиллу `reader-ux` (`tts-playback.md` §1 «авто-прокрутка», §2). Передаётся `ios-dev`.

## Проблема (две стороны одного)
1. **Reflow-ползунок дёргает аудио.** Слайдер вызывает `model.seek(toFraction:)` → перескакивает ПОЗИЦИЯ ОЗВУЧКИ. Должен только прокручивать ВИД; аудио переключается лишь по явному действию (тап «Отсюда» / skip).
2. **Вид насильно скроллит к чтению на каждой смене предложения.** Reflow — `scrollRangeToVisible`; PDF — `view.go(to:)`/`go(to:union)`. Если юзер сам проскроллил/зумнул (смотрит другое место) — это сбивает.

## Целевое поведение (единое для reflow и PDF)
- **По умолчанию вид следует за чтением** (как сейчас): на смену предложения — подскролл к подсветке.
- **Ручное действие приостанавливает следование:** пользовательский скролл (pan), зум (pinch, PDF), перетаскивание прогресс-слайдера/скраббера. После этого смена предложения **НЕ** двигает вид.
- **Кнопка возврата:** пока следование приостановлено И подсвеченное (читаемое) предложение НЕ видно во вьюпорте — показывать **полупрозрачную круглую иконку-кнопку справа внизу**. Тап → проскроллить к читаемому предложению и **возобновить следование**. Прятать кнопку, когда подсветка видна или следование активно.
- **Reflow-слайдер = просмотр (скролл), не аудио:** перетаскивание скроллит текст к доле книги (приостанавливает следование, показывает кнопку возврата если чтение ушло из вида). `seek` аудио НЕ вызывает. «%» и глава — по позиции ПРОКРУТКИ.
- **Явный перенос чтения возобновляет следование:** тап «Отсюда» (▶) → `play(from:)` + проскролл к новой подсветке + следование снова активно.

PDF-скраббер (`pageBar`) уже двигает только вид (не аудио) — оставить; но его переход тоже должен приостанавливать следование (browse), как и pinch-зум.

---

## Реализация

### 1. `ReflowReaderView` (UITextView) — следование + скролл-репорт + команды

Coordinator становится делегатом скролла: `tv.delegate = coordinator` (UITextViewDelegate наследует UIScrollViewDelegate).

Состояние Coordinator:
- `var isFollowing = true`

Новые входы (UIViewRepresentable-параметры):
- `var onScroll: (_ fraction: Double, _ topChapter: Int, _ highlightVisible: Bool, _ isFollowing: Bool) -> Void` — звать на скролл и после применения подсветки. `fraction = contentOffset.y / max(1, contentSize.height - bounds.height)`; `topChapter` — глава у верха вьюпорта (см. ниже); `highlightVisible` — пересекается ли rect текущей подсветки с видимой областью.
- `var command: ReflowCommand?` — тегированная команда: `enum ReflowCommand: Equatable { case scrollToFraction(Double, token: Int); case returnToReading(token: Int) }`. Применять в `updateUIView` при смене токена.

Логика:
- `scrollViewWillBeginDragging` → `isFollowing = false`; затем сообщить наверх (`reportScroll`).
- `scrollViewDidScroll` → `reportScroll` (фракция/глава/видимость), но НЕ менять isFollowing (программный скролл не должен сбрасывать).
- `applyHighlight(_:)` (на смене предложения): подсветку ставим ВСЕГДА; `scrollRangeToVisible(range)` — **только если `isFollowing`**. После — `reportScroll`.
- Команда `.scrollToFraction(f)` → выставить `contentOffset.y = f * (contentSize.height - bounds.height)`; `isFollowing = false` (browse); `reportScroll`.
- Команда `.returnToReading` → `scrollRangeToVisible(highlightRange)`; `isFollowing = true`; `reportScroll`.
- `topChapter`: charIndex у верха = `tv.closestPosition(to: CGPoint(x: inset.left+1, y: contentOffset.y + inset.top + 1))` → `offset(...)` → найти главу по `parent.chapterOffsets` (последний offset ≤ charIndex).
- `highlightVisible`: rect подсветки через `layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)` (+ inset.top), проверить пересечение с `CGRect(x:0, y: contentOffset.y, w: bounds.w, h: bounds.h)`. Если подсветки нет (нет highlight) → считать visible=true (кнопку не показывать).

### 2. `PDFKitView` — следование + кнопка возврата (слайдер уже view-only)

Состояние Coordinator: `var isFollowing = true`.

Детект ручного взаимодействия (надёжно, без подмены делегата PDFView):
- В `attachScrollTrackingIfNeeded` дополнительно: `scrollView.panGestureRecognizer.addTarget(self, #selector(userInteracted))` и, если есть, `scrollView.pinchGestureRecognizer?.addTarget(self, #selector(userInteracted))`.
- `@objc func userInteracted` → `isFollowing = false`; сообщить наверх.

Новые входы:
- `var onFollowChanged: (_ highlightVisible: Bool, _ isFollowing: Bool) -> Void`.
- `var returnToReadingToken: Int` — при изменении: проскроллить к текущей подсветке (`go(to: selection)` / `go(to: union, on:)`) и `isFollowing = true`.

Логика в `updateUIView` (блок подсветки, строки 82–108): `view.go(to: selection)` / `view.go(to: union, on:)` вызывать **только если `coordinator.isFollowing`**. Подсветку (`highlightedSelections`/аннотации) ставить всегда. После — вычислить `highlightVisible` (видна ли страница/область подсветки: сравнить страницу подсветки с `reportVisiblePage`/проверить пересечение `view.convert(selection.bounds(for:page), from: page)` с `view.bounds`) и позвать `onFollowChanged`.

PDF-скраббер: в `requestJump`/применении `pageJump` дополнительно гасить следование. Проще — пометить: при применении `pageJump` в `updateUIView` ставить `isFollowing = false` (это browse). Тогда после скраббинга вид не дёргается, появляется кнопка возврата.

### 3. `ReaderView` — кнопка возврата + проводка слайдера

Состояния:
- `@State private var showReturnButton = false`
- `@State private var reflowScrollFraction = 0.0` (заменяет смысл `reflowProgress` для слайдера — теперь это позиция скролла)
- `@State private var reflowTopChapter = 0`
- `@State private var reflowCommandToken = 0`, `@State private var reflowCommand: ReflowReaderView.ReflowCommand?`
- `@State private var pdfReturnToken = 0`

**reflowContent / pdfContent:** добавить overlay-кнопку возврата (bottom-trailing):
```swift
.overlay(alignment: .bottomTrailing) {
    if showReturnButton {
        Button { returnToReading() } label: {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                .foregroundStyle(Theme.accent)
                .opacity(0.85)
        }
        .padding(.trailing, 16).padding(.bottom, 12)
        .transition(.scale.combined(with: .opacity))
    }
}
```
`returnToReading()`: для reflow → выставить `reflowCommand = .returnToReading(token: ++)`; для PDF → `pdfReturnToken += 1`. (Определять активный путь по `model.isReflowable`.)

**ReflowReaderView вызов** — добавить:
- `onScroll: { f, ch, vis, following in reflowScrollFraction = f; reflowTopChapter = ch; withAnimation { showReturnButton = !following && !vis } }`
- `command: reflowCommand`

**PDFKitView вызов** — добавить:
- `onFollowChanged: { vis, following in withAnimation { showReturnButton = !following && !vis } }`
- `returnToReadingToken: pdfReturnToken`

**reflowBar (слайдер):**
- `Slider(value: $reflowScrollFraction, in: 0...1) { editing in if !editing { reflowCommandToken += 1; reflowCommand = .scrollToFraction(reflowScrollFraction, token: reflowCommandToken) } }` — на отпускании скроллим вид. Во время drag вид может скроллиться вживую (по желанию: слать команду и в onChange). **Убрать** вызов `model.seek(toFraction:)`.
- «%»: `Int(reflowScrollFraction * 100)`. Глава: `reflowTopChapter + 1`/`model.chapterCount`.
- Убрать `.onChange(of: model.reflowProgress)` (слайдер больше не привязан к позиции озвучки). Вместо — значение приходит из `onScroll`.

**playHereBubble:** после `model.speech.play(from: index)` — возобновить следование: для reflow `reflowCommand = .returnToReading(token: ++)`, для PDF `pdfReturnToken += 1`. (Чтобы вид снова поехал за чтением с новой точки.)

### 4. `ReaderViewModel`
- `seek(toFraction:)` больше НЕ используется слайдером — оставить метод (может пригодиться) или удалить, на усмотрение. `reflowProgress`/`onChange` для слайдера не нужны.
- Добавить хелпер при необходимости: `func chapter(forCharIndex:)` — но маппинг главы по charIndex проще держать внутри ReflowReaderView (есть chapterOffsets). Решай по месту.

---

## ⛔ Инвариант PDF (как в R4)
PDF-пагинация/скраббер/миниатюры/«читать отсюда»/OCR — не ломать. Изменения PDF строго: (а) `go(to:)` под `if isFollowing`, (б) детект pan/pinch, (в) кнопка возврата. Поведение по умолчанию (следование) идентично прежнему, пока юзер не вмешался.

## Чеклист приёмки (проверю через idb)
- [ ] Reflow: перетаскивание слайдера СКРОЛЛИТ текст, аудио НЕ перескакивает; «%»/глава отражают прокрутку.
- [ ] Reflow/PDF: после ручного скролла смена предложения НЕ дёргает вид.
- [ ] Когда чтение ушло из вида — справа внизу полупрозрачная кнопка; тап → возврат к чтению + следование возобновляется.
- [ ] Тап «Отсюда» ▶ → играет с предложения И вид снова следует.
- [ ] PDF-зум: после pinch вид не сбрасывается на смене предложения; кнопка возврата работает.
- [ ] Регресс: пока юзер не трогал — вид следует за чтением как раньше (reflow и PDF).
- [ ] Доступность: у кнопки возврата `accessibilityLabel("Вернуться к чтению")`; тап-цель ≥44.

## Объём
M→L. Файлы: `ReflowReaderView.swift`, `PDFKitView.swift`, `ReaderView.swift` (+ возможно `ReaderViewModel.swift`). Новых файлов нет → `xcodegen` не нужен. Проверка — idb на книге Норвуд (EPUB/FB2/PDF).
