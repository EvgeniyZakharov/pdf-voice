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

Приоритетный язык озвучки — **русский** (голос Milena Enhanced).

---

## Архитектура

```
PDFVoice/
├── App/            PDFVoiceApp.swift
├── Core/
│   ├── SpeechEngine.swift        — AVSpeechSynthesizer + Silero, очередь utterances, фон/прерывания
│   ├── TTSProvider.swift         — протокол-шов для будущего облачного TTS
│   ├── PDFTextExtractor.swift    — извлечение предложений из текстового слоя
│   ├── OCRTextExtractor.swift    — Vision OCR для сканов, поддерживает pageRange
│   ├── TextNormalizer.swift      — чистка: колонтитулы, переносы, аббревиатуры, ссылки
│   ├── SentencePageCache.swift   — кэш предложений на диск с отслеживанием частичной загрузки
│   ├── OCRCache.swift            — старый OCR-кэш (backward compat, читается SentencePageCache)
│   ├── NowPlayingController.swift — экран блокировки, Пункт управления, MPRemoteCommandCenter
│   └── SleepTimer.swift
├── Reader/
│   ├── ReaderViewModel.swift     — вся логика загрузки: текст/OCR/кэш/прогрессивная загрузка
│   ├── ReaderView.swift          — UI читалки, плеер, тулбар
│   ├── PDFKitView.swift          — UIViewRepresentable, подсветка предложений, тапы
│   ├── BookmarksView.swift       — список закладок, добавление через +
│   └── ThumbnailGridView.swift   — сетка миниатюр страниц
├── Library/
│   ├── LibraryView.swift
│   └── DocumentStore.swift       — JSON-хранилище библиотеки
├── Models/
│   └── LibraryItem.swift         — LibraryItem + Bookmark (Codable)
├── Settings/
│   ├── SettingsStore.swift
│   └── SettingsView.swift
└── Onboarding/
    └── OnboardingView.swift
```

---

## Ключевые решения (почему так)

**Прогрессивная загрузка PDF:**
- Текстовые PDF > 20 стр: читаем 15 стр на main thread → `finishLoading` (TTS доступен) → остальные страницы в `Task.detached(priority: .background)`
- OCR-PDF: OCR первых 15 стр → `finishLoading` → OCR остальных в фоне
- `document = doc` ставится ОДНОВРЕМЕННО с `finishLoading`, чтобы PDF и кнопка Play появлялись вместе

**Кэш `SentencePageCache`:**
- Хранит предложения + `loadedPageCount` + `totalPageCount`
- Сохраняется инкрементально после каждого батча (50 стр)
- При переоткрытии: частичный кэш → немедленно показывает что есть + продолжает загрузку
- Backward compat: при отсутствии нового кэша читает старый `OCRCache`

**`hasTextLayer` по плотности букв (порог 0.35):**
- Не проверяем «есть ли символы» — PDF с битой CMap-кодировкой отдаёт мусор (~1% букв), кириллица теряется → уходит в OCR. Нормальный текстовый PDF даёт ~95% букв.

**OCR-подсветка:** через `PDFAnnotation(.highlight)` по боксам строк (не через `highlightedSelections` — у OCR нет текстового диапазона).

**AVSpeechSynthesizer — очередь сразу:** все utterances ставятся разом при `play(from:)`. Это убирает повторное чтение, которое возникало при схеме «доречь следующее в didFinish».

**Миниатюры:** последовательный рендер на 1 фоновой очереди + копия PDFDocument. Параллельные рендеры вешали скролл.

**Тап по ячейке миниатюр:** `.onTapGesture`, не `Button` — Button в ScrollView срабатывал при отпускании после скролла.

---

## Что сделано

- **M1** Каркас: библиотека, читалка, базовый TTS
- **M2** Подсветка по предложениям (`NLTokenizer`), позиция, выбор голоса, тап «Читать отсюда», скорости 0.5–2.5×
- **Навигация** Скраббер страниц + сетка миниатюр
- **M4** `TextNormalizer`: колонтитулы, номера страниц, строки-лидеры оглавления, переносы, аббревиатуры, многоточия, ссылки/email через `NSDataDetector`
- **M5** Фоновое воспроизведение + экран блокировки: `AVAudioSession(.playback)`, `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`, обработка аудио-прерываний
- **M3** OCR для сканов через Vision, кэш результатов
- **Прогрессивная загрузка** Первые 15 страниц → мгновенный старт, остальное в фоне с инкрементальным кэшем
- **Закладки** Список + добавление + переход + удалением свайпом
- **Silero TTS** Локальный Python-сервер как альтернатива системному голосу

---

## Бэклог

- Русские ударения-омографы (за́мок/замо́к) — нужен словарь
- Числа → слова (склонение числительных)
- Листинги кода — детект и замена на «листинг»
- Мусор в заголовках (layout-анализ)
- Reflow-режим «только текст» (не рендерим PDF-страницу)
- App Store: иконка, скриншоты, описание

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
```

`library.json` — массив `LibraryItem` с датами в Apple timestamp (секунды от 2001-01-01).

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
