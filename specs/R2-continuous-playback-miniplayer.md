# R2 — Непрерывное воспроизведение при выходе в библиотеку + мини-плеер

**Статус:** спроектировано, в работе
**Сложность:** L · **Приоритет:** Top
**Связано:** R1 (таймер сна), R6 (голос в плеере), R12 (закладки без принудительного play)

---

## Проблема

Сессия чтения целиком принадлежит `ReaderView`:

```swift
@StateObject private var model: ReaderViewModel   // владеет speech, sleepTimer, nowPlaying
...
.onDisappear { model.endSession() }               // pause() + nowPlaying.teardown()
```

При возврате в библиотеку `ReaderView` уничтожается → `@StateObject` освобождается →
`endSession()` ставит на паузу и сносит Now Playing. Аудио обрывается. Это противоречит
конвенции «аудио — это медиаплеер»: уход на другой экран приложения **не должен** прерывать
воспроизведение (та же логика, что и фон/экран блокировки, которые уже работают).

## Цель

1. Воспроизведение продолжается при возврате в библиотеку (и при навигации внутри приложения).
2. Внизу `LibraryView` — компактный **мини-плеер**: обложка, заголовок, play/pause, закрыть (✕).
   Тап по строке → возврат в читалку этой книги.

## Инвариант (не сломать)

- Синхронизация `displayDocument` ↔ аудио (`loadedPageCount` двигается только после
  `speech.appendSentences`) — вся загрузка остаётся в `ReaderViewModel` **без изменений**.
- Lifecycle `NowPlayingController` — теперь живёт, пока жива сессия (создаётся в
  `finishLoading`, сносится в `endSession`). Это **усиление**: на экране блокировки контролы
  остаются активны и в библиотеке.
- Одновременно играет **одна** книга (один `SpeechEngine`/`AVAudioSession`).
- PDF-пагинация, reflow-навигация, follow-режим (R17) — не тронуты.

---

## Архитектура

Поднимаем сессию выше `ReaderView` в новый объект-владелец `PlaybackCoordinator`,
инъектируемый на уровне `App` как `@EnvironmentObject`. Активная сессия ровно одна.

```
PDFVoiceApp
 ├ DocumentStore        (@StateObject)
 ├ SettingsStore        (@StateObject)
 └ PlaybackCoordinator  (@StateObject)  ← держит active: ReaderViewModel?
      LibraryView
       ├ list/grid → NavigationLink(value: item)        (push ReaderView)
       ├ safeAreaInset(.bottom): MiniPlayerView(active)  ← только на корневом экране
       └ navigationDestination → ReaderView(item)
            └ ReaderScreen(model: coordinator.active)    (@ObservedObject)
```

### `Core/PlaybackCoordinator.swift` (новый)

```swift
@MainActor
final class PlaybackCoordinator: ObservableObject {
    @Published private(set) var active: ReaderViewModel?
    private let store: DocumentStore
    private let settings: SettingsStore

    init(store:settings:) { ... }

    /// Сессия для item: переиспользуем ту же, иначе сносим прежнюю и создаём новую.
    @discardableResult
    func open(_ item: LibraryItem) -> ReaderViewModel {
        if let m = active, m.itemID == item.id { return m }
        active?.endSession()                       // полный teardown прежней книги
        let m = ReaderViewModel(item: item, store: store)
        m.attach(store: store); m.applySettings(settings); m.load()
        active = m
        return m
    }

    func stop() { active?.endSession(); active = nil }          // ✕ в мини-плеере
    func stopIfActive(_ id: UUID) { if active?.itemID == id { stop() } }   // удаление книги
}
```

### `ReaderViewModel` (правка)

- `var itemID: UUID { item.id }`
- `var libraryItem: LibraryItem { item }` — для мини-плеера (обложка/заголовок).
- `endSession()` без изменений; вызывается теперь только при замене/стопе, **не** на каждый
  уход с экрана.

### `ReaderView` (правка — расщепление)

`ReaderView` становится тонким резолвером; тело переезжает в `ReaderScreen`:

```swift
struct ReaderView: View {            // в navigationDestination
    let item: LibraryItem
    @EnvironmentObject var coordinator: PlaybackCoordinator
    var body: some View {
        if let model = coordinator.active, model.itemID == item.id {
            ReaderScreen(model: model)                 // @ObservedObject
        } else {
            ProgressView().onAppear { coordinator.open(item) }   // мелькает 1 кадр
        }
    }
}
```

`ReaderScreen` = нынешнее тело `ReaderView`, но:
- `@ObservedObject var model` вместо `@StateObject` (владение — у координатора);
- `.onAppear` больше **не** делает `attach/applySettings/load` (это сделал координатор) —
  только `settings.probeSilero()`;
- **`.onDisappear` НЕ вызывает `endSession()`** — ключевое изменение R2;
- `.onChange(of: settings.selectedVoice)` → `model.applySettings(settings)` сохраняется.

### `MiniPlayerView` (новый, `Library/`)

```swift
struct MiniPlayerView: View {
    @ObservedObject var model: ReaderViewModel
    @ObservedObject var speech: SpeechEngine     // isSpeaking — живой play/pause
    let onOpen: () -> Void
    let onClose: () -> Void
    // [обложка 40×56] [title 1 стр.] —— [play/pause] [✕]
    // тап по строке (кроме кнопок) → onOpen
}
```

Тап-цели ≥44pt, `accessibilityLabel` на кнопки. Высота строки ~64pt, `.ultraThinMaterial` +
`Divider` сверху.

### `LibraryView` (правка)

- `@EnvironmentObject var coordinator`.
- `NavigationStack(path: $path)` (`@State path: [LibraryItem] = []`), чтобы мини-плеер мог
  программно вернуть в книгу: `path.append(model.libraryItem)`. `NavigationLink(value:)`
  продолжает работать (аппендит в path).
- `.safeAreaInset(edge: .bottom)` на корневом контенте: если `coordinator.active != nil` —
  `MiniPlayerView`. `safeAreaInset` резервирует место, список не прячется под плеером.
  Оверлей на **корневом** контенте → при пуше `ReaderView` он естественно перекрыт.
- В `deleteItems`/`delete` — `coordinator.stopIfActive(item.id)`.

### `PDFVoiceApp` (правка)

```swift
init() {
    let store = DocumentStore(); let settings = SettingsStore()
    _store = StateObject(wrappedValue: store)
    _settings = StateObject(wrappedValue: settings)
    _coordinator = StateObject(wrappedValue: PlaybackCoordinator(store: store, settings: settings))
}
... .environmentObject(coordinator)
```

---

## Сценарии / краевые случаи

| Сценарий | Поведение |
|----------|-----------|
| Играет книга A → назад в библиотеку | аудио продолжает, мини-плеер для A (live play/pause) |
| Из мини-плеера тап по строке | push `ReaderView(A)`; `coordinator.active` уже A → без перезагрузки |
| В библиотеке открыть книгу B | `open(B)` сносит A (`endSession`: stop + Now Playing teardown), грузит B |
| ✕ в мини-плеере | `stop()` — пауза, teardown, `active=nil`, плеер исчезает |
| Удалить активную книгу | `stopIfActive` → сессия снята |
| Пауза, затем в библиотеку | мини-плеер в состоянии паузы, resume возможен |
| Повторный вход в книгу | `ReaderScreen` пересоздаётся (свежие @State), `model` жив (currentIndex/loadedPageCount целы); вид скроллится к читаемому предложению (как при первом открытии) |

**Out of scope:** восстановление сессии после перезапуска приложения (позиция и так хранится
в `currentSentenceIndex`); мини-плеер на экранах настроек/онбординга (только библиотека).

---

## Проверка

- Компиляция: `xcodegen generate` (новые файлы подхватятся глоб-паттерном) + `xcodebuild`.
- idb на симуляторе: открыть книгу, начать чтение, назад в библиотеку → мини-плеер виден,
  индикатор play активен; тап play/pause переключает; тап по строке возвращает в читалку на
  текущем месте; открытие другой книги переключает сессию; ✕ убирает плеер.
- Аудио на слух (пользователь): звук не прерывается при уходе в библиотеку.
```