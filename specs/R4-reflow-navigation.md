# R4 — Навигация reflow-книг. Спецификация для реализации

Спроектировано по скиллу `reader-ux` (`references/ux-conventions.md` §5, `tts-playback.md`).
Решение принято в `UX_RECOMMENDATIONS.md` (R4). Передаётся `ios-dev`.

## Цель
Дать reflow-книгам (TXT/FB2/EPUB/DOCX) навигацию, которой сейчас нет вообще: **ползунок +
процент книги** + опциональное **«Содержание»** (главы). PDF не трогаем — у него свой
`pageBar` (страницы).

## ⛔ Жёсткий инвариант: PDF-читалка и её пагинация НЕ меняются
Мы проектируем **только путь reflow** (TXT/FB2/EPUB/DOCX). Работа PDF должна остаться
**побайтно прежней**. Это значит:
- **Не трогаем** `PDFKitView`, `pageBar`, `displayDocument`, `loadedPageCount`,
  `revealPages`, `requestPriorityLoad`, `updateVisiblePage`, `PageJump`, классификацию
  страниц и весь конвейер прогрессивной загрузки/OCR.
- Все изменения **аддитивны или под веткой `if model.isReflowable`**. Для PDF
  (`isReflowable == false`) поток исполнения остаётся идентичным текущему.
- Новый `SpeechEngine.seek(to:)` — **новый** метод; существующие `play(from:)`, `pause`,
  `resume`, `skip*`, `onIndexChange` НЕ меняются. PDF-путь `seek` не вызывает.
- Новые свойства/методы `ReaderViewModel` и `ChapterListView` PDF-путь не использует.
- reflow-панель использует **собственное** состояние скролла (`isReflowScrubbing`), не
  делит `isScrubbing` с `pageBar`.
- Проверка `qa-tester` обязана включать регресс PDF: страницы, скраббер, миниатюры,
  «читать отсюда», OCR — работают как раньше.

## Ключевое проектное решение: прогресс по индексу предложения

Ползунок и «%» считаем от **позиции озвучки** `speech.currentIndex`, а НЕ от пиксельной
прокрутки `UITextView`. Почему так (а не «скролл %»):
- **Нет расхождения** view ↔ playback: одна позиция-истина. В аудио-first читалке прогресс =
  «где читается», как в Audible/Pocket Casts (скраббер = позиция воспроизведения).
- **Совпадает с сохраняемым** `currentSentenceIndex` и **переживает смену шрифта** (привязка
  к предложению, не к пикселям) — конвенция из `tts-playback.md` §8.
- **Не нужно** новой scroll-обвязки: подсветка уже авто-скроллит к `currentSentence`
  (`ReflowReaderView.applyHighlight` → `scrollRangeToVisible`). Сменили `currentIndex` →
  подсветка и текст сами едут в нужное место — и при игре, и на паузе.
- **«Гл. N/M» бесплатно:** в reflow `Sentence.pageIndex` = индекс главы (см.
  `ReflowExtractor.sentences`), а `M = bookContent.chapters.count`.

Компромисс (осознанный): если пользователь вручную листает текст молча (без воспроизведения),
ползунок не двигается — он отражает позицию чтения вслух, а ручной скролл это «просмотр».
Это ожидаемое поведение аудио-читалки.

## Раскладка нижней панели (reflow)

```
┌─────────────────────────────────────┐
│ ☰   ◀────────●──────────▶   37% Гл.4/12│
└─────────────────────────────────────┘
 TOC      ползунок прогресса     % + глава
```
- `☰` (`list.bullet`) — «Содержание». Показывать **только если глав > 1** (для TXT обычно
  одна «глава» — кнопки нет).
- Ползунок — `0...1`, бежит за чтением; перетаскивание = переход (seek), без принуд. запуска.
- Справа — «NN%» и (если глав > 1) «Гл. K/M».

---

## Изменения по файлам

### 1. `Core/SpeechEngine.swift` — добавить `seek(to:)`

Сейчас есть только `play(from:)` (всегда запускает звук). Нужен переход, уважающий play/pause:

```swift
/// Перейти к предложению, сохранив текущее play/pause.
/// Играет → продолжить с новой позиции; на паузе → только переставить позицию
/// (подсветка/скролл сдвинутся через @Published currentIndex) и сохранить прогресс.
func seek(to index: Int) {
    guard !sentences.isEmpty else { return }
    let i = clamp(index)
    if isSpeaking {
        play(from: i)            // перезапуск с новой позиции
    } else {
        currentIndex = i         // @Published → highlight + auto-scroll
        onIndexChange?(i)        // персист позиции даже без воспроизведения
    }
}
```
Примечание: это общий примитив — на него же позже переедет `navigate(to bm:)` (R12), чтобы
закладки не форсили play. В рамках R4 закладки не трогаем.

### 2. `Reader/ReaderViewModel.swift` — данные и методы для панели

Добавить вычисляемые свойства и методы (используют уже существующие `speech`, `bookContent`,
`currentSentence`):

```swift
// Прогресс по позиции озвучки (0...1).
var reflowProgress: Double {
    let n = speech.sentences.count
    guard n > 1 else { return 0 }
    return Double(speech.currentIndex) / Double(n - 1)
}

// Главы (reflow).
var chapterCount: Int { bookContent?.chapters.count ?? 0 }
var hasChapters: Bool { chapterCount > 1 }
var currentChapterIndex: Int { currentSentence?.pageIndex ?? 0 }   // pageIndex == индекс главы
var chapterTitles: [String] {
    (bookContent?.chapters.enumerated().map { i, ch in
        let t = ch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t?.isEmpty == false) ? t! : "Глава \(i + 1)"
    }) ?? []
}

// Переходы (уважают play/pause).
func seek(toFraction f: Double) {
    let n = speech.sentences.count
    guard n > 0 else { return }
    let idx = Int((f * Double(n - 1)).rounded())
    speech.seek(to: idx)
}
func seekToChapter(_ chapter: Int) {
    guard chapterFirstSentence.indices.contains(chapter) else { return }
    speech.seek(to: chapterFirstSentence[chapter])
}
```

Предрассчитать индекс первого предложения каждой главы (один раз, в `finishLoading` для
reflow-пути — там уже есть `sentences`):

```swift
// chapterFirstSentence[ch] = индекс в speech.sentences первого предложения главы ch.
private var chapterFirstSentence: [Int] = []
// заполнить: для каждого ch найти первый s где s.pageIndex == ch (предложения уже по порядку глав).
```

### 3. `Reader/ReaderView.swift` — показать `reflowBar` + лист «Содержание»

В `body` развести панель по типу формата (сейчас `pageBar` завязан на `loadedPageCount`,
который для reflow = 0 → панель не показывается):

```swift
if audioReady {
    if model.isReflowable {
        Divider(); reflowBar          // НОВОЕ — только для reflow
    } else if pageCount > 1 {
        Divider(); pageBar            // PDF — ветка идентична текущему поведению
    }
    Divider()
    PlayerControls(model: model)
}
```
Это единственная правка `body`. Для PDF (`isReflowable == false`) ветка
`else if pageCount > 1 { pageBar }` исполняется ровно как сейчас — поведение не меняется.

`reflowBar` (зеркало `pageBar`, но единица — %; state `@State reflowProgress` + `isScrubbing`,
синхронизация из `model.reflowProgress` через `onChange`, как у `scrubValue`/`currentPage`):

```swift
private var reflowBar: some View {
    HStack(spacing: 14) {
        if model.hasChapters {
            Button { showChapters = true } label: {
                Image(systemName: "list.bullet").font(.body)
            }
            .accessibilityLabel("Содержание")
        }
        Slider(value: $reflowProgress, in: 0...1) { editing in
            isReflowScrubbing = editing                 // отдельное состояние, не делим с pageBar
            if !editing { model.seek(toFraction: reflowProgress) }
        }
        .accessibilityValue("\(Int(reflowProgress * 100)) процентов")

        VStack(alignment: .trailing, spacing: 1) {
            Text("\(Int(reflowProgress * 100))%")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if model.hasChapters {
                Text("Гл. \(model.currentChapterIndex + 1)/\(model.chapterCount)")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 64, alignment: .trailing)
    }
    .padding(.horizontal).padding(.vertical, 6)
    .onChange(of: model.reflowProgress) { v in if !isReflowScrubbing { reflowProgress = v } }
}
```
Добавить НОВЫЕ `@State`: `private var showChapters = false`, `private var reflowProgress = 0.0`,
`private var isReflowScrubbing = false`. Существующие `scrubValue`/`isScrubbing` (для `pageBar`)
НЕ трогать. И `.sheet(isPresented: $showChapters)` → `ChapterListView` (ниже).

### 4. Новый файл `Reader/ChapterListView.swift` — лист «Содержание»

```swift
struct ChapterListView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(Array(model.chapterTitles.enumerated()), id: \.offset) { i, title in
                Button {
                    model.seekToChapter(i)     // seek, НЕ форсит play (R12)
                    dismiss()
                } label: {
                    HStack {
                        Text(title).foregroundStyle(.primary)
                        Spacer()
                        if i == model.currentChapterIndex {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            .navigationTitle("Содержание")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```
Если файл новый — добавить в `project.yml` не нужно (XcodeGen берёт по папкам), но
**перегенерировать проект** (`xcodegen generate`) перед сборкой.

### 5. (Кросс-ссылка R16, опц. полировка) комфортная зона авто-скролла
`ReflowReaderView.applyHighlight` сейчас `scrollRangeToVisible` — фрагмент может оказаться у
нижнего края. По `tts-playback.md` §1 держать активное предложение в верхней трети. Можно
доработать в рамках R16 (проверка подсветки), не блокирует R4.

---

## Доступность (обязательно, см. `accessibility.md`)
- `☰` → `accessibilityLabel("Содержание")`.
- Ползунок → `accessibilityValue` «NN процентов».
- Строки глав читаются заголовком; текущая глава различима не только цветом (галочка ✓ —
  уже есть в макете).
- Тап-цель `☰` ≥ 44×44.

## Чеклист приёмки
- [ ] У reflow-книги внизу есть ползунок + «%» (раньше панели не было вовсе)
- [ ] Ползунок едет за озвучкой; перетаскивание переходит без обрыва/принуд. старта
- [ ] На паузе перетаскивание двигает подсветку и текст (превью), play не стартует
- [ ] «Гл. K/M» корректна; кнопка «Содержание» только при глав > 1
- [ ] «Содержание» прыгает к началу главы, текущая глава отмечена, play не форсится
- [ ] Позиция сохраняется (seek персистит `currentSentenceIndex`)
- [ ] Доступность: метки/value/тап-цели
- [ ] **Регресс PDF (обязательно):** скраббер по страницам, миниатюры, «стр. N/M»,
      «читать отсюда», прогрессивная загрузка и OCR работают как раньше; `pageBar` не изменён;
      производительность не просела

## Объём для ios-dev
- S→M. Файлы: `SpeechEngine.swift` (+`seek`), `ReaderViewModel.swift` (+свойства/методы,
  предрасчёт глав), `ReaderView.swift` (+`reflowBar`, sheet), новый `ChapterListView.swift`.
  После добавления файла — `xcodegen generate`. Проверка — `qa-tester` на реальных EPUB/FB2/TXT.

## Не делаем (граница объёма)
- Горизонтальное листание (отклонено).
- Прогресс в библиотеке (R5 — отдельно).
- Переезд закладок на `seek` (R12 — отдельно, но `seek` уже готов под него).