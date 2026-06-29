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
| TTS нейросетевой | Silero — свой сервер `tts.pdf-voice.com` (`silero-server/`, деплой `silero-server/deploy/`) |
| Хранилище | Codable JSON в Documents (не SwiftData — iOS 16.0 min) |
| Сборка | XcodeGen → `.xcodeproj` не хранится в репо |
| Bundle ID | `com.pdfvoice.app` |
| Min iOS | 16.0 |

Приоритетный язык озвучки — **русский** (Silero — основной движок для ударений, Milena — офлайн-фолбэк).

См. также `ARCHITECTURE.md` (целевая архитектура + спайки) и `IMPLEMENTATION.md` (план фаз).
Работа идёт в **`main`** (ветка `feature/scalable-architecture` влита и удалена).

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
│   ├── SileroBackend.swift        — Silero (fetch-play-loop); истинный pause/resume (AVAudioPlayer
│   │                                pause→продолжение с позиции); ударения как «+» после гласной
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
│   ├── ReaderViewModel.swift     — загрузка: классификация → text/ocr/mixed/reflow, прогрессивно,
│   │                                displayDocument; reflow: bookContent/chapterOffsets, seek, главы
│   ├── ReaderView.swift          — UI читалки; pageBar (PDF) / reflowBar (ползунок+%+Содержание);
│   │                                кнопка «Вернуться к чтению»; playHereBubble (иконка ▶)
│   ├── PDFKitView.swift          — UIViewRepresentable PDF; растущий displayDocument; подсветка;
│   │                                follow-режим (go(to:) под isFollowing)
│   ├── ReflowReaderView.swift    — UITextView (TextKit 1) для reflow; подсветка диапазоном;
│   │                                тап→ближайшее предложение; follow-режим + ReflowCommand
│   ├── ChapterListView.swift     — лист «Содержание» (главы reflow), переход без принуд. play
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

**Silero истинный pause/resume:** `SileroBackend.pause()` ставит `AVAudioPlayer.pause()` (сохраняет `currentTime`), `resume()` доигрывает текущий клип с места и продолжает очередь с `queueIndex+1`. `SpeechEngine.resume()` различает «пауза посреди предложения» (`isPausedMidClip` → продолжить) и «старт» (`play(from:)`). Раньше Silero перечитывал предложение с начала.

**Reflow-рендер и навигация (R4):** reflow-форматы (TXT/FB2/EPUB/DOCX) рендерятся в `ReflowReaderView` — один `UITextView` (TextKit 1, `usingTextLayoutManager:false` — нужен `textStorage` для подсветки) с плоским текстом книги (`BookContent.flatten`). Навигация — `reflowBar` (не `pageBar`): ползунок = позиция ПРОКРУТКИ, «%» книги, «Содержание» (`ChapterListView`) при глав>1. «Страница N/M» в reflow нет (текст перетекает). Тап → БЛИЖАЙШЕЕ предложение (`closestPosition` + минимальная дистанция до диапазона; строгое `NSLocationInRange` промахивалось на зазорах `\n\n` между абзацами/главами).

**Развязка «позиция чтения» ↔ «позиция просмотра» (R17, reflow и PDF):** вид следует за подсветкой только при `isFollowing`. Ручной скролл / зум (PDF) / драг ползунка → `isFollowing=false` → смена предложения НЕ дёргает вид. Полупрозрачная кнопка «Вернуться к чтению» (справа внизу) показывается, когда читаемое предложение ушло из вида; тап → скролл к подсветке + следование. Аудио/позиция чтения переключается ТОЛЬКО явно (тап «Отсюда» ▶ / skip) — ползунок reflow аудио НЕ двигает (скроллит вид). Детект ручного жеста: reflow — `UITextViewDelegate.scrollViewWillBeginDragging`; PDF — target на `panGestureRecognizer`/`pinchGestureRecognizer`. **Инвариант:** по умолчанию (юзер не вмешался) следование идентично прежнему; PDF-пагинация/`pageBar`/миниатюры не тронуты.

**Silero и ATS:** прод по HTTPS (`tts.pdf-voice.com`) проходит ATS по умолчанию. `NSAppTransportSecurity.NSAllowsLocalNetworking` в `Info.plist` оставлен для локальной разработки (cleartext http к localhost). Сервер требует `X-API-Key` (прод — `.env`, локально — `.api_key`).

**Миниатюры:** последовательный рендер на 1 фоновой очереди + копия PDFDocument по URL.

**Тап по ячейке миниатюр:** `.onTapGesture`, не `Button`.

---

## Что сделано

**Базовое (M1–M5):** библиотека, читалка, подсветка по предложениям (`NLTokenizer`), выбор голоса, «Читать отсюда», скорости, скраббер + сетка миниатюр, фон + экран блокировки (`AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`, прерывания), OCR через Vision, закладки, Silero TTS.

**Рефакторинг под масштабируемость (влито в `main`):**
- **Фаза 0a — швы:** late render (`rawText` + кэш v2); `LanguageProfile`+`TextPipeline`; `SpeechBackend` (AVSpeech/Silero за швом); ATS-фикс для Silero.
- **Фаза 1 — русское качество:** ударения омографов (словарь 20 слов → `+` в Silero); склонение числительных по предлогу («от 2 до 5» → «от двух до пяти»); единицы («5 кг» → «пять килограммов») и контекстные аббревиатуры («г. Москва» → «город», «см.» vs «5 см»).
- **Фаза 0b — робастность PDF:** постраничный `classifyPage`; единый конвейер очистки OCR (паритет с текстом); `loadMixed` для смешанных PDF; фикс `requestPriorityLoad` для OCR; оконный детект колонтитулов; под-строчные OCR-боксы.
- **UX:** показ только готовых к озвучке страниц (`displayDocument`); синхронизация аудио ↔ показа страниц.

**Читалка reflow-форматов и UX озвучки (idb-проверено на EPUB/FB2/PDF):**
- **R4 — навигация reflow:** `reflowBar` (ползунок=скролл + «%» + «Содержание»/главы), `ChapterListView`, `seek` без принуд. play. PDF-`pageBar` не тронут.
- **R17 — развязка чтения/просмотра:** follow-режим (`isFollowing`) + кнопка «Вернуться к чтению»; ползунок reflow скроллит вид (реактивно), аудио не дёргает.
- **Фиксы:** тап «Отсюда» в reflow (ближайшее предложение + `closestPosition` + координаты пузырька при прокрутке); истинный pause/resume Silero (не перечитывает предложение); пузырёк «Отсюда» → иконка-кнопка ▶.

**Прод и подготовка к релизу:**
- **Silero на сервере:** вынесен из локального quick-tunnel на отдельную машину (Hetzner CX23) за постоянным HTTPS `https://tts.pdf-voice.com` (Cloudflare named-tunnel, без открытых портов). Деплой воспроизводим: `silero-server/deploy/` (`DEPLOY.md`, systemd-юниты, `benchmark.py`). CPU-torch, `WORKERS`/`TORCH_THREADS` под нагрузку.
- **Приложение зашито на прод:** `sileroServerURL`/`sileroAPIKey` — константы, поля в Настройках убраны, подключение к нейроголосам автоматическое.
- **Offline-fallback:** при недоступном сервере `SpeechEngine` беззвучно переходит на системный голос (`SpeechEvent.failed` → `fallBackToSystemVoice`), без обрыва чтения — снимает риск App Store.

Все логические этапы проверены автономными Swift-харнессами (компиляция реальных файлов + ассерты) и golden-регрессией. UI/визуал и интерактив (тап, скролл, кнопки) проверяются в симуляторе через **idb** (accessibility-дерево + тап/свайп) + скриншоты `simctl`. Аудио на слух проверяет пользователь.

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
CONTAINER=$(xcrun simctl get_app_container booted com.pdfvoice.app data)
cp mybook.pdf "$CONTAINER/Documents/"
# сброс кэша → свежий проход извлечения/OCR:
rm -rf "$CONTAINER/Documents/page-cache"
```

`library.json` — массив `LibraryItem` с датами в Apple timestamp (секунды от 2001-01-01).
Пример: `[{"id":"<uuid>","fileName":"mybook.pdf","title":"…","addedDate":770000000,"lastOpenedDate":770000000,"currentSentenceIndex":0,"bookmarks":[]}]`

**Проверка логики без симулятора** (быстро, без GUI): компилировать нужные `Core/`-файлы
напрямую через `swiftc` + harness с `main.swift` и ассертами. Тексто-чистка/лингвистика
тестируются так (см. историю: golden-регрессия, тесты ударений/числительных, OCR на
реальных страницах через Vision).

**UI/интерактив в симуляторе через `idb`** (установлен; CLI на PATH `/opt/homebrew/bin/idb`):
`idb ui describe-all --udid <UDID>` — accessibility-дерево (искать элемент по `AXLabel`, брать
центр `frame`); `idb ui tap/swipe` — тап/скролл без угадывания координат; `xcrun simctl io
booted screenshot` — скриншот. Так проверяются тап «Отсюда», скролл/ползунок, кнопка возврата
и т.п. Аудио на слух — только пользователь.

---

## Silero TTS

**Прод:** сервер развёрнут на Hetzner, работает 24/7 за `https://tts.pdf-voice.com`
(Cloudflare Tunnel). Приложение зашито на этот адрес (`SettingsStore.sileroServerURL`/`sileroAPIKey`
— константы, поля в Настройках убраны). Развёртывание: `silero-server/deploy/DEPLOY.md`.
При недоступном сервере `SpeechEngine` беззвучно откатывается на системный голос
(событие `SpeechEvent.failed` → `fallBackToSystemVoice`).

**Локальная разработка:** `cd silero-server && ./start.sh` поднимает сервер на
`localhost:8000` для обкатки правок `server.py` через curl (см. `silero-server/README.md`).
Голоса: aidar, baya, kseniya, xenia, eugene.

---

## Агенты

В `.claude/agents/` специализированные агенты:
- `ios-dev` — пишет Swift/SwiftUI код, не запускает
- `qa-tester` — собирает и запускает в симуляторе, не пишет код
- `silero-backend` — Python/FastAPI сервер, не трогает Swift
- `ux-ui-designer` — анализирует экраны и текущий функционал, предлагает улучшения дизайна и новые фичи с привязкой к экранам; код не пишет
- `code-auditor` — ищет баги, дубли, мёртвый код и проблемы производительности, даёт рекомендации по оптимизации; код не правит (фиксит `ios-dev`)

## Скиллы

В `.claude/skills/` доменные скиллы проекта:
- `reader-ux` — эксперт по проектированию/ревью читалок с TTS-озвучкой: общепринятые
  UX-конвенции жанра + правила корректной обработки форматов (PDF/TXT/FB2/EPUB/DOCX).
  Справочники: `ux-conventions.md`, `formats.md`, `tts-playback.md`, `accessibility.md`.
  Применять при любой работе над фичей читалки (дизайн, навигация, плеер, подсветка, форматы,
  доступность). Связан с рабочим файлом `UX_RECOMMENDATIONS.md`.
