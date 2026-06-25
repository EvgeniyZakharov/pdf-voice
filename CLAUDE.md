# PDF Voice — CLAUDE.md

iOS-приложение для чтения PDF вслух. Мотивация: на рынке нет бесплатных достойных приложений.

---

## Стек и ограничения

| Что | Решение |
|-----|---------|
| UI | SwiftUI |
| PDF | PDFKit (рендер + текстовый слой) |
| OCR для сканов | Vision (`VNRecognizeTextRequest`, ru-RU/en-US) |
| TTS основной | `AVSpeechSynthesizer` (офлайн, бесплатно) |
| TTS альтернативный | Silero — локальный Python-сервер (`silero-server/`) |
| Хранилище | Codable JSON в Documents (не SwiftData — iOS 16.0 min) |
| Сборка | XcodeGen → `.xcodeproj` не хранится в репо |
| Bundle ID | `com.pollsar.pdfvoice` |
| Min iOS | 16.0 |

Приоритетный язык озвучки — **русский** (Silero — основной движок для ударений, Milena — офлайн-фолбэк).

См. также `ARCHITECTURE.md` (целевая архитектура + спайки) и `IMPLEMENTATION.md` (план фаз).
Текущая ветка работ: **`feature/scalable-architecture`**.

---

## Архитектура

Движок «PDF → текст → речь» разнесён по двум осям масштабирования: **язык** за
`LanguageProfile` и **движок синтеза** за `SpeechBackend`. Конвейер очистки общий
для текста и OCR (`TextPipeline`).

```
PDFVoice/
├── App/            PDFVoiceApp.swift
├── Core/
│   ├── LanguageProfile.swift      — протокол языка: токенизация, isHeading, render→SpokenMarkup
│   ├── RussianProfile.swift       — русский: числа (склонение по предлогу), аббревиатуры,
│   │                                ударения (словарь омографов → SpokenMarkup.stresses)
│   ├── TextPipeline.swift         — ЯЗЫК-НЕЗАВИСИМОЕ: строки, offset-карта, переносы,
│   │                                колонтитулы (detectBoilerplate + Windowed), номера страниц
│   ├── SpeechBackend.swift        — протокол движка синтеза + SpeechEvent + SpokenMarkup
│   ├── AVSpeechBackend.swift      — AVSpeechSynthesizer (enqueue-all); ударения U+0301 игнорит
│   ├── SileroBackend.swift        — Silero (fetch-play-loop); ударения рендерит как «+» после гласной
│   ├── SpeechEngine.swift         — КООРДИНАТОР: выбор backend, очередь-намерение, подсветка
│   │                                из событий, Now-Playing, прерывания; render на воспроизведении
│   ├── TTSProvider.swift          — протокол-шов (load/play/pause/...)
│   ├── PageClassifier.swift       — classifyPage/textDensityKind → .text/.ocr/.skip; isBlankPage
│   ├── PDFTextExtractor.swift     — извлечение предложений из текстового слоя + mergeCrossPage
│   ├── OCRTextExtractor.swift     — Vision OCR → ЕДИНЫЙ конвейер TextPipeline; под-строчные боксы
│   ├── TextNormalizer.swift       — ПУСТОЙ stub (логика переехала в TextPipeline/RussianProfile)
│   ├── SentencePageCache.swift    — кэш предложений (schemaVersion=2, хранит rawText), частичная загрузка
│   ├── OCRCache.swift             — легаси (compile-only; v2-кэш его не читает)
│   ├── NowPlayingController.swift — экран блокировки, MPRemoteCommandCenter
│   └── SleepTimer.swift
├── Reader/
│   ├── ReaderViewModel.swift     — загрузка: классификация → text/ocr/mixed, прогрессивно,
│   │                                displayDocument (показ только готовых страниц)
│   ├── ReaderView.swift          — UI читалки; preparingView; показ только готовых страниц
│   ├── PDFKitView.swift          — UIViewRepresentable; растущий displayDocument; подсветка
│   ├── BookmarksView.swift       — список закладок
│   └── ThumbnailGridView.swift   — сетка миниатюр; плейсхолдеры для неготовых страниц
├── Library/  (LibraryView, DocumentStore, BookCoverView)
├── Models/   (LibraryItem + Bookmark)
├── Settings/ (SettingsStore, SettingsView)
└── Onboarding/ (OnboardingView)
```

---

## Ключевые решения (почему так)

**Late render (кэш хранит сырое, раскрытие на воспроизведении):**
- `Sentence.rawText` — СЫРОЕ очищенное предложение (+ `language`). `expandForSpeech` (числа→слова, аббревиатуры, ударения) применяется в `SpeechEngine.render` при постановке в очередь, НЕ при извлечении.
- Зачем: улучшения лингвистики НЕ инвалидируют кэш. `SentencePageCache` версионируется (`schemaVersion=2`); старые кэши со «спикен»-текстом игнорируются.

**`LanguageProfile` / `TextPipeline` (ось «язык»):**
- `TextPipeline` — язык-независимая механика (строки, offset-карта, склейка переносов, колонтитулы, номера страниц, leader-строки, `mergeCrossPage`).
- `RussianProfile` — всё русское: токенизация (локаль), `isHeading`, `render`→`SpokenMarkup`.
- Новый язык = новый профиль, без трогания механики. Рефакторинг проверен golden-тестом (вывод побайтно идентичен).

**`SpeechBackend` (ось «движок»):**
- `SpeechEngine` — координатор (очередь-намерение, подсветка из `SpeechEvent`, Now-Playing, прерывания). Конкретный синтез за `SpeechBackend`. Убрано ветвление `if sileroServerURL`.
- Ударения: профиль даёт ПОЗИЦИИ (`SpokenMarkup.stresses`); рендерит backend. **Спайк подтвердил:** Silero уважает `+` после ударной гласной, AVSpeech `U+0301` ИГНОРИТ → Silero основной движок для ударений, AVSpeech фолбэк без стресса.

**Постраничный тип + единый конвейер OCR:**
- `classifyPage` решает ПОСТРАНИЧНО (`.text/.ocr/.skip`) по плотности букв (порог 0.35; битая CMap → ~1% букв → OCR). `isBlankPage` (рендер 48×48, дисперсия яркости) — ленивый, off-main.
- OCR идёт через ТОТ ЖЕ `TextPipeline` что и текст → паритет (колонтитулы/паузы на сканах). Документ-уровень: только text → `loadText`; только ocr → `loadOCR`; смешанный → `loadMixed` (страницы в ПОРЯДКЕ номеров).
- **Колонтитулы на больших книгах:** `detectBoilerplateWindowed` (окна 30 стр.) — порог `max(3,n/5)` на 705-стр. батче давал 141, заголовки глав (~20×) не ловились.
- **OCR-подсветка:** под-строчные боксы через `VNRecognizedText.boundingBox(for:)` (не вся строка — иначе подсвечивались чужие слова), фолбэк на полную строку.

**Показ только готовых к озвучке страниц (`displayDocument`):**
- PDFView показывает не весь документ, а `displayDocument` — растущую копию страниц `[0, loadedPageCount)`. Растёт через `didSet loadedPageCount → revealPages` (копии страниц; мутация и чтение на main — гонок нет). PDFView подхватывает новые через `layoutDocumentView()` без сброса скролла.
- **Инвариант синхронизации:** во ВСЕХ путях `loadedPageCount` двигается ТОЛЬКО после `speech.appendSentences` — открытая страница всегда имеет аудио. (OCR-остаток обрабатывается батчами по 15 ради этого; раньше аудио добавлялось одним куском в конце → страница видна, играть нечего.)
- Скраббер/сетка ограничены готовыми; неготовые в сетке — плейсхолдер «загружается». До первой готовой — `preparingView` («Распознаём текст… %»).

**AVSpeechSynthesizer — очередь сразу:** все utterances ставятся разом (в `AVSpeechBackend`). Убирает повторное чтение. Смена скорости/голоса = пере-наполнение очереди (AVSpeech не умеет менять темп посреди предложения — отсюда рестарт текущего; у Silero темп меняется на лету).

**Silero и ATS:** сервер по HTTP localhost — в `Info.plist` нужен `NSAppTransportSecurity.NSAllowsLocalNetworking` (иначе iOS блокирует cleartext). Сервер требует `X-API-Key` (ключ в `silero-server/.api_key`).

**Миниатюры:** последовательный рендер на 1 фоновой очереди + копия PDFDocument по URL.

**Тап по ячейке миниатюр:** `.onTapGesture`, не `Button`.

---

## Что сделано

**Базовое (M1–M5):** библиотека, читалка, подсветка по предложениям (`NLTokenizer`), выбор голоса, «Читать отсюда», скорости, скраббер + сетка миниатюр, фон + экран блокировки (`AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`, прерывания), OCR через Vision, закладки, Silero TTS.

**Рефакторинг под масштабируемость (ветка `feature/scalable-architecture`):**
- **Фаза 0a — швы:** late render (`rawText` + кэш v2); `LanguageProfile`+`TextPipeline`; `SpeechBackend` (AVSpeech/Silero за швом); ATS-фикс для Silero.
- **Фаза 1 — русское качество:** ударения омографов (словарь 20 слов → `+` в Silero); склонение числительных по предлогу («от 2 до 5» → «от двух до пяти»); единицы («5 кг» → «пять килограммов») и контекстные аббревиатуры («г. Москва» → «город», «см.» vs «5 см»).
- **Фаза 0b — робастность PDF:** постраничный `classifyPage`; единый конвейер очистки OCR (паритет с текстом); `loadMixed` для смешанных PDF; фикс `requestPriorityLoad` для OCR; оконный детект колонтитулов; под-строчные OCR-боксы.
- **UX:** показ только готовых к озвучке страниц (`displayDocument`); синхронизация аудио ↔ показа страниц.

Все логические этапы проверены автономными Swift-харнессами (компиляция реальных файлов + ассерты) и golden-регрессией. Аудио/визуал проверяет пользователь вручную.

---

## Бэклог

- **Омографы по контексту (S4b):** за́мок/замо́к — плоский словарь не различает, нужен анализ окружения. Расширять словарь однозначных ударений (сейчас 20 слов) — безопасно инкрементально.
- **Род числительных в именительном (S5b):** «2 страницы» → «две» — нужна морфология существительного. Сейчас падежный путь только при предлоге.
- **Годы/века:** «1999 г.» → «тысяча девятьсот девяносто девятого года» — порядковое склонение.
- **Конкурентный OCR-lane (§3.6):** сейчас страницы строго по порядку (порядок предложений важнее латентности).
- Листинги кода → «листинг»; мусор в заголовках (layout-анализ); reflow-режим «только текст»; App Store (иконка, скриншоты).

---

## Сборка

```bash
cd /Users/evgeniy/projects/pdf-voice
xcodegen generate
xcodebuild -project PDFVoice.xcodeproj -scheme PDFVoice \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build
```

**Тест без GUI:** скопировать PDF + `library.json` в Documents контейнера:
```bash
CONTAINER=$(xcrun simctl get_app_container booted com.pollsar.pdfvoice data)
cp mybook.pdf "$CONTAINER/Documents/"
# сброс кэша → свежий проход извлечения/OCR:
rm -rf "$CONTAINER/Documents/page-cache"
```

`library.json` — массив `LibraryItem` с датами в Apple timestamp (секунды от 2001-01-01).
Пример: `[{"id":"<uuid>","fileName":"mybook.pdf","title":"…","addedDate":770000000,"lastOpenedDate":770000000,"currentSentenceIndex":0,"bookmarks":[]}]`

**Проверка логики без симулятора** (быстро, без GUI): компилировать нужные `Core/`-файлы
напрямую через `swiftc` + harness с `main.swift` и ассертами. Тексто-чистка/лингвистика
тестируются так (см. историю: golden-регрессия, тесты ударений/числительных, OCR на
реальных страницах через Vision). Аудио и визуал PDFView — только глазами/слухом в
симуляторе (пользователь).

---

## Silero TTS

```bash
cd silero-server && ./start.sh   # создаёт .venv, скачивает модель ~200MB
```

Сервер на `http://0.0.0.0:8000`. В Settings приложения: включить Silero + URL. Голоса: aidar, baya, kseniya, xenia, eugene.

---

## Агенты

В `.claude/agents/` три специализированных агента:
- `ios-dev` — пишет Swift/SwiftUI код, не запускает
- `qa-tester` — собирает и запускает в симуляторе, не пишет код
- `silero-backend` — Python/FastAPI сервер, не трогает Swift
