import AVFoundation
import Combine
import Foundation
import PDFKit

/// Логика экрана чтения: загрузка PDF, извлечение предложений, связь со SpeechEngine.
@MainActor
final class ReaderViewModel: ObservableObject {
    @Published private(set) var document: PDFDocument?
    @Published private(set) var loadError: String?
    @Published private(set) var ocrProgress: Double?
    @Published private(set) var bookmarks: [Bookmark] = []
    @Published private(set) var isLoadingRemainingPages = false
    @Published private(set) var loadedPageCount: Int = 0 {
        didSet { revealPages(upTo: loadedPageCount) }
    }

    /// Растущий документ: содержит только страницы [0, loadedPageCount).
    /// PDFKitView показывает его — пользователь не может прокрутить на неготовую страницу.
    let displayDocument = PDFDocument()

    // MARK: - Reflow (TXT/FB2/EPUB/DOCX)
    /// Логическая модель reflow-книги (nil для PDF). Наличие → показываем ReflowReaderView.
    @Published private(set) var bookContent: BookContent?
    /// Плоский текст книги для TextKit-рендера (см. `BookContent.flatten`).
    private(set) var reflowFlatText: String = ""
    /// Глобальные смещения начала глав — для маппинга подсветки предложения.
    private(set) var reflowChapterOffsets: [Int] = []
    /// Перетекающий ли формат — развилка слоя отображения в `ReaderView`.
    var isReflowable: Bool { item.format.isReflowable }

    // Предрасчитанный индекс первого предложения каждой главы.
    // chapterFirstSentence[ch] = индекс в speech.sentences; count == chapterCount.
    // Заполняется однократно в finishLoading для reflow-пути.
    private var chapterFirstSentence: [Int] = []

    let speech = SpeechEngine()

    private var item: LibraryItem
    private weak var store: DocumentStore?
    /// Языковой профиль книги — один на сессию чтения, из `item.language`.
    /// Пока детект не отработал (язык `nil`) это русский профиль, то есть
    /// поведение приложения не меняется.
    private var profile: any LanguageProfile {
        LanguageProfiles.profile(for: item.effectiveLanguage)
    }
    /// Последние применённые настройки — чтобы перевыбрать голос после детекта
    /// языка (он отрабатывает уже в процессе загрузки книги).
    private var lastSettings: SettingsStore?
    private var cancellables = Set<AnyCancellable>()
    private var nowPlaying: NowPlayingController?
    private var totalPageCount: Int = 0
    private var backgroundTask: Task<Void, Never>?
    /// Сохранённая позиция (`item.currentSentenceIndex`), которая на момент
    /// `finishLoading` вышла за пределы первого загруженного батча предложений.
    /// `SpeechEngine.load` клампит startIndex по тому, что уже загружено — без
    /// этого поля позиция терялась бы, если пользователь жмёт ▶ до того, как
    /// фоновая загрузка догонит сохранённый индекс. Сбрасывается либо когда
    /// становится достижимым (`tryApplyPendingRestore`), либо на любое явное
    /// действие пользователя (он сам выбрал новое место).
    private var pendingRestoreIndex: Int?
    /// Полный исходный документ — источник страниц для displayDocument. Трогать
    /// только с main thread (растёт через revealPages).
    private var sourceDoc: PDFDocument?
    /// Отдельная копия того же файла — ЕДИНСТВЕННЫЙ источник страниц для всех
    /// фоновых чтений (классификация, page.string, OCR, blank-check). PDFKit не
    /// потокобезопасен: `sourceDoc`/`document` растут на main через revealPages
    /// одновременно с фоновой загрузкой — общий объект гонял бы чтение и мутацию
    /// с разных потоков.
    private var extractionDoc: PDFDocument?

    // Постраничная классификация для смешанного режима.
    private var pageKinds: [PageKind] = []

    /// Идентификатор книги — координатор сравнивает сессии по нему.
    var itemID: UUID { item.id }
    /// Книга сессии — для мини-плеера (обложка/заголовок) и возврата в читалку.
    var libraryItem: LibraryItem { item }

    init(item: LibraryItem, store: DocumentStore?) {
        self.item = item
        self.store = store
        speech.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Скорость меняется прямо в плеере читалки (`speech.speed = …`), а не
        // через SettingsStore — прокидываем выбор обратно в настройки здесь,
        // чтобы тёмп пережил закрытие книги (см. У9, скорость глобальная).
        speech.onSpeedChange = { [weak self] newSpeed in
            self?.lastSettings?.playbackSpeed = newSpeed
        }
    }

    func attach(store: DocumentStore) {
        self.store = store
        bookmarks = store.items.first(where: { $0.id == item.id })?.bookmarks ?? []
        // Один раз за сессию — в отличие от прогресса (см. persistProgress),
        // который копится и льётся по дебаунсу на каждое предложение.
        store.markOpened(item.id)
        speech.onIndexChange = { [weak self] index in
            guard let self else { return }
            // Пока не применилось отложенное восстановление позиции, а событие
            // пришло с индексом МЕНЬШЕ него — это озвучка префикса, догоняющего
            // сохранённую позицию, а не пользователь слушающий книгу сначала.
            // Не затираем сохранённый прогресс промежуточными индексами.
            if let pending = self.pendingRestoreIndex, index < pending { return }
            self.store?.updateProgress(for: self.item.id, sentenceIndex: index)
        }
        speech.onFinishedAll = { [weak self] in
            guard let self else { return }
            self.store?.markFinished(self.item.id)
        }
    }

    /// Последний выбор голоса, на который эта сессия уже отреагировала (ключ —
    /// выбор ДЛЯ ЯЗЫКА ТЕКУЩЕЙ КНИГИ, см. ниже). `changeVoice` вызывается из ДВУХ
    /// независимых слушателей одного и того же реального изменения в Настройках —
    /// `ReaderView.onChange` (пока открыта читалка) и `PlaybackCoordinator`
    /// (фоновая сессия за мини-плеером); когда читалка открыта, срабатывают ОБА
    /// на одно и то же событие. Без этого ключа второй вызов не отличил бы «ничего
    /// не изменилось с прошлого раза» от «пользователь снова сменил голос» и
    /// рестартовал бы звук ещё раз поверх уже идущего рестарта первого вызова.
    private var lastVoiceSelection: String?

    /// Смена голоса на лету: применяем настройки и, если книга сейчас читается,
    /// делаем чистый «пауза → play» — старый голос сразу смолкает, текущее
    /// предложение перечитывается новым голосом с начала. Смена backend'а
    /// (система ↔ Silero) и смена голоса AVSpeech сами перезапускают игру внутри
    /// `applySettings` (см. `SpeechEngine.didRestartSincePrepare`); смена
    /// спикера Silero ВНУТРИ backend'а авто-перезапуска не даёт — его и
    /// добавляет этот явный `restartCurrent()`, но только если ни один из
    /// путей `applySettings` уже не рестартовал сам (иначе двойной рестарт).
    func changeVoice(_ settings: SettingsStore) {
        let selection = effectiveVoiceSelection(settings)
        guard selection != lastVoiceSelection else {
            // Тот же реальный выбор, что мы уже применили (второй слушатель того
            // же события) — прочие поля (пауза и т.п.) синхронизируем, но без
            // рестарта звука.
            applySettings(settings)
            return
        }
        lastVoiceSelection = selection
        let wasSpeaking = speech.isSpeaking
        speech.prepareForSettingsChange()
        applySettings(settings)
        if wasSpeaking, !speech.didRestartSincePrepare {
            speech.restartCurrent()
        }
    }

    /// Смена голоса ЭТОЙ книги (пикер в читалке): пишет `voiceID` в модель книги
    /// с немедленным сохранением (`DocumentStore.setVoice`, не через дебаунс
    /// прогресса) и применяет на лету — тем же путём, что и `changeVoice`.
    /// Настройки (глобальный дефолт) не трогает: книга с выбранным голосом
    /// больше не зависит от них.
    func selectVoice(_ voiceID: String, settings: SettingsStore) {
        item.voiceID = voiceID
        store?.setVoice(voiceID, for: item.id)
        changeVoice(settings)
    }

    /// Эффективный голос книги: собственный выбор (`item.voiceID`), если он есть
    /// И валиден для языка книги, иначе — глобальный дефолт из Настроек по языку
    /// книги. Невалидность бывает у ru-Silero-спикера на английской книге
    /// (Silero знает только русский) — тогда книжный выбор игнорируется, как и
    /// голос, убранный из каталога.
    func effectiveVoiceSelection(_ settings: SettingsStore) -> String {
        let language = item.effectiveLanguage
        let fallback = VoiceCatalog.isEnglish(language) ? settings.selectedVoiceEN : settings.selectedVoice
        guard let voiceID = item.voiceID, VoiceCatalog.isValid(voiceID, for: language) else {
            return fallback
        }
        return voiceID
    }

    func applySettings(_ settings: SettingsStore) {
        // Запоминаем настройки, чтобы перевыбрать голос, когда язык книги
        // определится по ходу загрузки (детект идёт уже после первого applySettings).
        lastSettings = settings
        speech.pauseBetweenSentences = settings.pauseBetweenSentences
        // Скорость — глобальная настройка (не по-книжная): применяем сохранённый
        // темп при каждом открытии/пере-применении настроек. Обратная связь —
        // `speech.onSpeedChange`, когда пользователь меняет темп в плеере читалки.
        speech.speed = settings.playbackSpeed
        speech.sileroAPIKey = settings.sileroAPIKey
        // Профиль книги — для late render (числа/аббревиатуры/ударения при
        // постановке предложения в очередь). Выбор голоса по языку — шаг 5.
        speech.profile = profile

        // Голос — эффективный для КНИГИ (собственный выбор `item.voiceID`, если
        // валиден, иначе дефолт Настроек по языку книги): английскую книгу
        // русский голос читает с сильным акцентом (фонетику задаёт голос, а не
        // текст), да и Silero знает только русский — см. `effectiveVoiceSelection`.
        let isEnglishBook = VoiceCatalog.isEnglish(item.effectiveLanguage)
        let sel = effectiveVoiceSelection(settings)
        // Голос/спикер выставляем ДО переключения sileroServerURL: его didSet может
        // авто-продолжить озвучку новым backend'ом, и тот должен быть уже настроен.
        if sel.hasPrefix("silero:"), !isEnglishBook, !settings.sileroServerURL.isEmpty {
            speech.sileroSpeaker = String(sel.dropFirst("silero:".count))
            speech.sileroServerURL = URL(string: settings.sileroServerURL)
        } else {
            // Системный голос (или откат на него, если Silero недоступен).
            let id = sel.hasPrefix("sys:") ? String(sel.dropFirst("sys:".count)) : sel
            if let v = AVSpeechSynthesisVoice(identifier: id) { speech.voice = v }
            speech.sileroServerURL = nil
        }
    }

    // MARK: - Состояние для UI

    var currentSentence: Sentence? {
        guard speech.sentences.indices.contains(speech.currentIndex) else { return nil }
        return speech.sentences[speech.currentIndex]
    }

    var currentSentenceText: String { currentSentence?.rawText ?? "" }

    /// Полное число страниц в исходном документе (включая ещё не загруженные).
    var totalPages: Int { totalPageCount }

    // MARK: - Reflow навигация

    var chapterCount: Int { bookContent?.chapters.count ?? 0 }
    /// Показывать кнопку «Содержание» только если глав > 1 (у TXT обычно одна).
    var hasChapters: Bool { chapterCount > 1 }
    /// Индекс текущей главы: в reflow-пути sentence.pageIndex == индекс главы.
    var currentChapterIndex: Int { currentSentence?.pageIndex ?? 0 }

    var chapterTitles: [String] {
        (bookContent?.chapters.enumerated().map { i, ch in
            let t = ch.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t?.isEmpty == false) ? t! : "Глава \(i + 1)"
        }) ?? []
    }

    /// Перейти к началу главы, сохранив play/pause.
    func seekToChapter(_ chapter: Int) {
        guard chapterFirstSentence.indices.contains(chapter) else { return }
        clearPendingRestore()
        speech.seek(to: chapterFirstSentence[chapter])
    }

    // MARK: - Явные действия пользователя (сбрасывают pendingRestoreIndex)

    /// Отменяет отложенное восстановление сохранённой позиции: пользователь сам
    /// явно выбрал место (тап «Отсюда», skip, закладка, глава) — его выбор важнее.
    private func clearPendingRestore() { pendingRestoreIndex = nil }

    /// «Читать отсюда» (пузырёк в читалке).
    func playFrom(_ index: Int) {
        clearPendingRestore()
        speech.play(from: index)
    }

    func skipForward() {
        clearPendingRestore()
        speech.skipForward()
    }

    func skipBackward() {
        clearPendingRestore()
        speech.skipBackward()
    }

    // MARK: - Растущий документ

    /// Добавляет в displayDocument страницы вплоть до n-й (не включая),
    /// копируя их из sourceDoc. Вызывается только с main thread (@MainActor).
    private func revealPages(upTo n: Int) {
        guard let src = sourceDoc else { return }
        let target = min(n, src.pageCount)
        while displayDocument.pageCount < target {
            let i = displayDocument.pageCount
            guard let p = src.page(at: i)?.copy() as? PDFPage else { break }
            displayDocument.insert(p, at: i)
        }
    }

    /// Ленивый off-main blank-чек (рендер 48×48 + разброс яркости) — общий хелпер
    /// для всех мест, которым нужно решить «стоит ли гонять OCR на этой странице».
    private func isPageBlank(_ page: PDFPage) async -> Bool {
        await Task.detached(priority: .background) { isBlankPage(page) }.value
    }

    /// Накопленный набор ключей колонтитулов (см. `TextPipeline.normalizedKey`).
    /// Растёт по ходу загрузки текстового/смешанного пути — плоский
    /// `detectBoilerplate` на разных, несогласованных по объёму выборках
    /// (первые 15 страниц / остаток / батчи по 10 в mixed) давал нестабильный
    /// результат (порог зависел от размера конкретной выборки); оконный
    /// детект + объединение с уже найденным делают набор только растущим и не
    /// зависящим от того, в какой фазе загрузки страница обработана.
    private var boilerplateKeys: Set<String> = []

    // MARK: - Загрузка

    func load() {
        // Reflow-форматы не имеют PDFDocument — ветка ДО PDF-гарда.
        if item.format.isReflowable {
            loadReflow()
            return
        }
        guard let doc = PDFDocument(url: item.fileURL) else {
            loadError = "Не удалось открыть PDF."
            return
        }
        totalPageCount = doc.pageCount
        sourceDoc = doc

        // Кэш проверяем ДО классификации: у полностью загруженной (ранее уже
        // прочитанной) книги плотность букв по page.string всей книги
        // пересчитывать незачем — это и была львиная доля фриза открытия
        // большой книги (1-8 с даже когда всё уже посчитано).
        let cached = SentencePageCache.load(for: item.fileName)
        if let cached, cached.isComplete {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, doc.pageCount)
            finishLoading(sentences)
            speech.isFullyLoaded = true
            return
        }

        // Кэша нет либо он неполный — классификация (page.string по каждой
        // странице) обязательна и дорогая, уводим на фон вместе с открытием
        // ВТОРОЙ копии PDFDocument той же книги: main растит sourceDoc/document
        // параллельно (revealPages), а PDFKit не потокобезопасен — фоновые
        // пути должны читать СВОЙ объект (extractionDoc), не тот, что мутируется.
        let url = item.fileURL
        let shouldDetect = needsLanguageDetection

        backgroundTask = Task { [weak self] in
            let result: (extraction: PDFDocument, kinds: [PageKind], sample: String)? =
                await Task.detached(priority: .userInitiated) {
                    guard let extraction = PDFDocument(url: url) else { return nil }
                    var kinds: [PageKind] = []
                    kinds.reserveCapacity(extraction.pageCount)
                    for pi in 0..<extraction.pageCount {
                        if let page = extraction.page(at: pi) {
                            kinds.append(textDensityKind(page))
                        } else {
                            kinds.append(.ocr)
                        }
                    }
                    let sample = shouldDetect ? Self.textSample(doc: extraction, kinds: kinds) : ""
                    return (extraction, kinds, sample)
                }.value

            guard !Task.isCancelled, let self else { return }
            guard let result else {
                self.loadError = "Не удалось открыть PDF."
                return
            }
            self.extractionDoc = result.extraction
            self.pageKinds = result.kinds

            // Язык — ДО любой ветки извлечения: он выбирает профиль, а профиль
            // проставляет isHeading, который уходит в кэш предложений.
            if shouldDetect, !result.sample.isEmpty {
                self.resolveLanguage(from: result.sample)
            }

            let hasText = result.kinds.contains(.text)
            let hasOCR  = result.kinds.contains(.ocr)

            switch (hasText, hasOCR) {
            case (true, false):
                // Чисто текстовый — проверенный путь без изменений.
                self.loadText(doc, extractionDoc: result.extraction, cached: cached)
            case (false, _):
                // Чисто OCR — проверенный путь без изменений.
                self.loadOCR(doc, extractionDoc: result.extraction, cached: cached)
            default:
                // Смешанный: часть страниц с текстовым слоем, часть — сканы.
                self.loadMixed(doc, extractionDoc: result.extraction, cached: cached)
            }
        }
    }

    // MARK: - Язык книги

    /// Нужен ли детект: язык определяется ОДИН раз за книгу и дальше живёт в
    /// библиотеке. `nil` бывает у новых книг и у всех, добавленных до появления
    /// поля. Ручной выбор пользователя (шаг 6) детект тоже отключает — значение
    /// уже не nil.
    private var needsLanguageDetection: Bool { item.language == nil }

    /// Записывает определённый язык в модель и в библиотеку. Вызывать ДО
    /// построения предложений: `isHeading` уезжает в кэш, и первый проход не тем
    /// профилем испортил бы его надолго.
    private func resolveLanguage(from sample: String) {
        guard needsLanguageDetection,
              let code = LanguageDetector.detect(sample: sample) else { return }
        applyDetectedLanguage(code)
    }

    /// Записывает язык и ПЕРЕВЫБИРАЕТ голос: первый `applySettings` отработал до
    /// детекта, с языком по умолчанию, и английская книга иначе осталась бы на
    /// русском голосе до следующего открытия.
    private func applyDetectedLanguage(_ code: String) {
        item.language = code
        store?.setLanguage(code, for: item.id)
        if let settings = lastSettings { applySettings(settings) }
    }

    /// Образец текста PDF: первые страницы с текстовым слоем.
    ///
    /// Берём его ТОЛЬКО если текстовых страниц хотя бы половина документа, то есть
    /// книга действительно текстовая. Иначе пустая строка — образец возьмётся из
    /// распознанных страниц (`loadOCR`) или из готовых предложений
    /// (`finishLoading`).
    ///
    /// Проверка не паранойя, а разбор реального провала: у скана русской книги
    /// (84 страницы) текстовый слой нашёлся ровно на ОДНОЙ — на списке литературы,
    /// где русские записи из-за битой CMap потеряли буквы, а английские выжили.
    /// Образец вышел «1093 латинских буквы, ноль кириллицы», и русская книга
    /// уверенно определилась как английская.
    nonisolated private static func textSample(doc: PDFDocument, kinds: [PageKind],
                                               maxPages: Int = 3, maxChars: Int = 4000) -> String {
        let textPages = kinds.filter { $0 == .text }.count
        guard doc.pageCount > 0, Double(textPages) / Double(doc.pageCount) >= 0.5 else { return "" }

        var sample = ""
        var used = 0
        for pi in 0..<doc.pageCount where used < maxPages {
            guard kinds.indices.contains(pi), kinds[pi] == .text,
                  let text = doc.page(at: pi)?.string, !text.isEmpty else { continue }
            sample += text + " "
            used += 1
            if sample.count >= maxChars { break }
        }
        return String(sample.prefix(maxChars))
    }

    // MARK: - Reflow-путь (TXT/FB2/EPUB/DOCX)

    /// Парсит reflow-книгу целиком off-main (текст быстрый — в отличие от OCR,
    /// постраничная прогрессия не нужна), затем кладёт предложения в плеер.
    /// Постраничная машинерия displayDocument/loadedPageCount НЕ используется.
    private func loadReflow() {
        let format = item.format
        let url = item.fileURL
        let fileName = item.fileName
        // Профиль поднимаем в локальную переменную: Task.detached выполняется вне
        // главного актора и не может читать @MainActor-свойство напрямую.
        let profile = profile
        let shouldDetect = needsLanguageDetection

        // Быстрый путь: язык уже известен (детект не нужен), кэш предложений
        // полон, и рядом лежит согласованный сайдкар (flatText + главы) —
        // открытие книги без повторного unzip/парсинга/токенизации всей книги.
        // Детект языка запускать заново не нужно: он один раз пишется в
        // `item.language`, а раз shouldDetect==false, значение уже есть.
        if !shouldDetect,
           let cached = SentencePageCache.load(for: fileName), cached.isComplete,
           let sidecar = SentencePageCache.loadReflowSidecar(for: fileName),
           sidecar.chapterTitles.count == cached.totalPageCount {
            let sentences = cached.entries.map { $0.toSentence() }
            bookContent = BookContent(chapters: sidecar.chapterTitles.map { BookChapter(title: $0, text: "") })
            reflowFlatText = sidecar.flatText
            reflowChapterOffsets = sidecar.chapterOffsets
            totalPageCount = cached.totalPageCount
            finishLoading(sentences)
            speech.isFullyLoaded = true
            return
        }

        backgroundTask = Task { [weak self] in
            let parsed: ReflowParse? = await Task.detached(priority: .userInitiated) {
                guard let source = Self.reflowSource(for: format, url: url) else { return nil }
                guard let content = try? source.parse(), !content.isEmpty else { return nil }
                let flat = content.flatten()
                // Детект ЗДЕСЬ, между парсингом и нарезкой: текст книги уже есть,
                // а предложения (с isHeading внутри) ещё не построены. Вынести
                // на main было бы вторым проходом парсинга.
                let detected = shouldDetect
                    ? LanguageDetector.detect(sample: String(flat.text.prefix(4000)))
                    : nil
                let effective = detected.map { LanguageProfiles.profile(for: $0) } ?? profile
                let sentences = ReflowExtractor.sentences(from: content, profile: effective)
                return ReflowParse(content: content, sentences: sentences,
                                   text: flat.text, chapterOffsets: flat.chapterOffsets,
                                   detectedLanguage: detected)
            }.value

            guard !Task.isCancelled, let self else { return }
            guard let parsed, !parsed.sentences.isEmpty else {
                self.loadError = "Не удалось извлечь текст из файла."
                return
            }
            if let detected = parsed.detectedLanguage, self.needsLanguageDetection {
                self.applyDetectedLanguage(detected)
            }

            self.bookContent = parsed.content
            self.reflowFlatText = parsed.text
            self.reflowChapterOffsets = parsed.chapterOffsets
            let chapterCount = parsed.content.chapters.count
            self.totalPageCount = chapterCount
            self.finishLoading(parsed.sentences)
            // Reflow парсится и режется на предложения ЦЕЛИКОМ за один проход —
            // прогрессивной догрузки для него нет, книга сразу полностью загружена.
            self.speech.isFullyLoaded = true

            // Кэшируем результат целиком (loadedPageCount == totalPageCount ==
            // число глав, isComplete=true), чтобы следующее открытие пошло
            // быстрым путём выше. Сохранение — off main, не блокирует UI.
            let sentencesSnapshot = parsed.sentences
            let flatText = parsed.text
            let chapterOffsets = parsed.chapterOffsets
            let chapterTitles = parsed.content.chapters.map(\.title)
            Task.detached(priority: .background) {
                SentencePageCache.save(sentences: sentencesSnapshot, loadedPageCount: chapterCount,
                                       totalPageCount: chapterCount, for: fileName)
                SentencePageCache.saveReflowSidecar(flatText: flatText, chapterOffsets: chapterOffsets,
                                                    chapterTitles: chapterTitles, for: fileName)
            }
        }
    }

    private struct ReflowParse {
        let content: BookContent
        let sentences: [Sentence]
        let text: String
        let chapterOffsets: [Int]
        /// Язык, определённый по тексту книги (nil — детект не запускался либо
        /// не дал уверенного ответа).
        let detectedLanguage: String?
    }

    nonisolated private static func reflowSource(for format: BookFormat, url: URL) -> ReflowSource? {
        switch format {
        case .txt: return PlainTextSource(url: url)
        case .fb2: return FB2Source(url: url)
        case .epub: return EPUBSource(url: url)
        case .docx: return DOCXSource(url: url)
        default: return nil   // .pdf/.djvu — не reflow
        }
    }

    // MARK: - Чисто текстовый путь (без изменений)

    private func loadText(_ doc: PDFDocument, extractionDoc: PDFDocument, cached: SentenceCacheEntry?) {
        let pageCount = doc.pageCount

        if let cached {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                startBackgroundTextLoading(doc: doc, extractionDoc: extractionDoc,
                                           from: cached.loadedPageCount,
                                           totalPageCount: pageCount, prior: sentences)
            } else {
                speech.isFullyLoaded = true
            }
            return
        }

        if pageCount <= 20 {
            let sentences = PDFTextExtractor.sentences(from: extractionDoc, profile: profile)
            document = doc
            loadedPageCount = pageCount
            finishLoading(sentences)
            speech.isFullyLoaded = true
            SentencePageCache.save(sentences: sentences, loadedPageCount: pageCount,
                                   totalPageCount: pageCount, for: item.fileName)
            return
        }

        loadTextProgressively(doc, extractionDoc: extractionDoc)
    }

    private func loadTextProgressively(_ doc: PDFDocument, extractionDoc: PDFDocument) {
        let pageCount = doc.pageCount
        let initialCount = min(15, pageCount)
        let initialLines: [[TextPipeline.PageLine]] = (0..<initialCount).map {
            TextPipeline.lines(of: extractionDoc.page(at: $0)?.string ?? "")
        }
        // Оконный детект + объединение с уже накопленным (пусто на первом батче,
        // растёт дальше в `startBackgroundTextLoading`/`processMixedPages`) —
        // см. `boilerplateKeys`.
        boilerplateKeys.formUnion(TextPipeline.detectBoilerplateWindowed(pages: initialLines))
        let quickBoilerplate = boilerplateKeys
        let fileName = item.fileName
        // Локальная копия для Task.detached (вне главного актора).
        let profile = profile

        backgroundTask = Task { [weak self] in
            let initial = await Task.detached(priority: .userInitiated) {
                PDFTextExtractor.extractSentences(
                    pageRange: 0..<initialCount,
                    allLines: initialLines,
                    boilerplate: quickBoilerplate,
                    profile: profile
                )
            }.value

            guard !Task.isCancelled, let self else { return }
            self.document = doc
            self.loadedPageCount = initialCount
            self.finishLoading(initial)
            SentencePageCache.save(sentences: initial, loadedPageCount: initialCount,
                                   totalPageCount: pageCount, for: fileName)

            guard initialCount < pageCount else {
                self.speech.isFullyLoaded = true
                return
            }
            self.isLoadingRemainingPages = true
            self.startBackgroundTextLoading(doc: doc, extractionDoc: extractionDoc, from: initialCount,
                                            totalPageCount: pageCount, prior: initial)
        }
    }

    private func startBackgroundTextLoading(doc: PDFDocument, extractionDoc: PDFDocument, from startPage: Int,
                                            totalPageCount: Int, prior: [Sentence]) {
        backgroundTask?.cancel()
        let fileName = item.fileName
        // Локальная копия для Task.detached (вне главного актора).
        let profile = profile
        // Снимок накопленного на момент старта фона — объединяется с оконным
        // детектом остатка ниже, чтобы набор колонтитулов только рос (см. T5,
        // `boilerplateKeys`), а не пересчитывался с нуля на каждой фазе.
        let priorBoilerplate = boilerplateKeys

        backgroundTask = Task { [weak self] in
            // Читаем строки страниц off main thread через GCD — только из extractionDoc,
            // НЕ из doc/sourceDoc (тот растёт на main через revealPages параллельно).
            let remainingLines: [[TextPipeline.PageLine]] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .background).async {
                    var lines: [[TextPipeline.PageLine]] = []
                    lines.reserveCapacity(totalPageCount - startPage)
                    for pi in startPage..<totalPageCount {
                        lines.append(TextPipeline.lines(of: extractionDoc.page(at: pi)?.string ?? ""))
                    }
                    cont.resume(returning: lines)
                }
            }

            guard !Task.isCancelled else { return }

            // Оконный детект boilerplate (окно 30 стр.) off main thread, объединённый
            // с уже найденным ранее — набор только растёт (T5).
            let windowed = await Task.detached(priority: .background) {
                TextPipeline.detectBoilerplateWindowed(pages: remainingLines)
            }.value
            let boilerplate = priorBoilerplate.union(windowed)

            guard !Task.isCancelled, let self else { return }
            self.boilerplateKeys = boilerplate

            var allSentences = prior
            let batchSize = 50
            var batchStart = 0

            while batchStart < remainingLines.count {
                // Отменённый таск (закрытие сессии/удаление книги) не должен
                // пересоздавать кэш удалённой/закрытой книги — просто выходим.
                guard !Task.isCancelled else { return }

                let batchEnd = min(batchStart + batchSize, remainingLines.count)

                // Извлечение предложений off main thread.
                let batch = await Task.detached(priority: .background) {
                    PDFTextExtractor.extractSentences(
                        pageRange: batchStart..<batchEnd,
                        allLines: remainingLines,
                        boilerplate: boilerplate,
                        pageOffset: startPage,
                        profile: profile
                    )
                }.value

                guard !Task.isCancelled else { return }
                allSentences.append(contentsOf: batch)
                self.speech.appendSentences(batch)
                self.tryApplyPendingRestore()
                self.loadedPageCount = startPage + batchEnd

                // Сохранение off main thread — не блокируем UI.
                let snap = allSentences; let loaded = startPage + batchEnd
                Task.detached(priority: .background) {
                    SentencePageCache.save(sentences: snap, loadedPageCount: loaded,
                                          totalPageCount: totalPageCount, for: fileName)
                }

                batchStart = batchEnd
            }

            guard !Task.isCancelled else { return }
            self.speech.isFullyLoaded = true
            self.isLoadingRemainingPages = false
        }
    }

    // MARK: - Чисто OCR путь

    private func loadOCR(_ doc: PDFDocument, extractionDoc: PDFDocument, cached: SentenceCacheEntry?) {
        let pageCount = doc.pageCount

        if let cached {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                runOCR(doc: doc, extractionDoc: extractionDoc, from: cached.loadedPageCount,
                       totalPageCount: pageCount, prior: sentences)
            } else {
                speech.isFullyLoaded = true
            }
            return
        }

        document = doc
        runOCR(doc: doc, extractionDoc: extractionDoc, from: 0, totalPageCount: pageCount, prior: [])
    }

    private func runOCR(doc: PDFDocument, extractionDoc: PDFDocument, from startPage: Int,
                        totalPageCount: Int, prior: [Sentence]) {
        ocrProgress = Double(startPage) / Double(totalPageCount)
        let fileName = item.fileName

        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            let initialCount = min(startPage + 15, totalPageCount)

            // Дебаунс сохранения кэша: JSON-энкод растущего массива предложений
            // синхронно на main-акторе внутри цикла — O(n²), 150-200 мс залипания
            // на каждый батч из 15 страниц к концу большой книги. Сохраняем не
            // чаще раза в 5 с, кроме форсированных точек (первый батч резюме и
            // последний батч книги — иначе конец книги мог остаться несохранённым).
            // Проверка Task.isCancelled ПЕРЕД спавном Task.detached — сама
            // detached-задача от отмены внешней НЕ зависит (не дочерняя), поэтому
            // отменённый цикл не должен успеть её запустить.
            var lastCacheSave = Date.distantPast
            let cacheSaveInterval: TimeInterval = 5
            func saveCache(_ sentences: [Sentence], loaded: Int, force: Bool) {
                guard !Task.isCancelled else { return }
                let now = Date()
                guard force || now.timeIntervalSince(lastCacheSave) >= cacheSaveInterval else { return }
                lastCacheSave = now
                Task.detached(priority: .background) {
                    SentencePageCache.save(sentences: sentences, loadedPageCount: loaded,
                                          totalPageCount: totalPageCount, for: fileName)
                }
            }

            // У скана текстового слоя нет, образец брать неоткуда — распознаём
            // несколько страниц заранее и определяем язык по ним. Эти страницы
            // будут распознаны ещё раз в основном проходе: сознательный размен
            // секунды на то, чтобы весь остальной OCR (и его кэш) строился уже
            // правильным профилем.
            //
            // Именно НЕСКОЛЬКО, а не одна: первая страница книги — обложка, и на
            // ней букв обычно меньше, чем нужно детектору (на проверенном скане
            // — 63 буквы против порога в 120). Копим, пока не наберётся образец.
            if needsLanguageDetection {
                var sample = ""
                var probed = 0
                var pi = startPage
                while pi < totalPageCount, probed < 3, sample.count < 1500 {
                    let probe = await OCRTextExtractor.sentences(
                        from: extractionDoc, pageRange: pi..<(pi + 1)
                    ) { _, _ in }
                    sample += probe.map(\.rawText).joined(separator: " ") + " "
                    probed += 1
                    pi += 1
                }
                resolveLanguage(from: sample)
            }

            if startPage < initialCount {
                let initial = await OCRTextExtractor.sentences(
                    from: extractionDoc,
                    pageRange: startPage..<initialCount,
                    profile: profile
                ) { [weak self] done, total in
                    let overall = Double(startPage + done) / Double(totalPageCount)
                    self?.ocrProgress = overall * 0.2
                }

                guard !Task.isCancelled else { return }
                let allInitial = prior + initial
                if !prior.isEmpty || !initial.isEmpty {
                    if prior.isEmpty {
                        finishLoading(allInitial)
                    } else {
                        speech.appendSentences(initial)
                        tryApplyPendingRestore()
                    }
                    loadedPageCount = initialCount
                    saveCache(allInitial, loaded: initialCount, force: true)
                }

                guard initialCount < totalPageCount else {
                    ocrProgress = nil
                    isLoadingRemainingPages = false
                    speech.isFullyLoaded = true
                    if allInitial.isEmpty {
                        loadError = "Не удалось распознать текст на страницах."
                    }
                    return
                }

                isLoadingRemainingPages = true

                // Остаток обрабатываем батчами: предложения добавляем в плеер И
                // двигаем loadedPageCount ВМЕСТЕ — страница «открывается» только
                // когда её аудио реально в speech.sentences. Иначе пользователь
                // видит готовую страницу, но не может её слушать.
                var allSentences = allInitial
                var batchStart = initialCount
                let batchSize = 15
                while batchStart < totalPageCount {
                    guard !Task.isCancelled else { return }
                    let batchEnd = min(batchStart + batchSize, totalPageCount)
                    let captureStart = batchStart
                    let batch = await OCRTextExtractor.sentences(
                        from: extractionDoc,
                        pageRange: batchStart..<batchEnd,
                        profile: profile
                    ) { [weak self] done, _ in
                        let overall = 0.2 + Double(captureStart + done) / Double(totalPageCount) * 0.8
                        self?.ocrProgress = min(overall, 0.99)
                    }
                    // Отменённый таск (закрытие сессии/удаление книги) не должен
                    // пересоздавать кэш удалённой/закрытой книги — проверяем ПЕРЕД
                    // append/save.
                    guard !Task.isCancelled else { return }
                    allSentences.append(contentsOf: batch)
                    speech.appendSentences(batch)   // сначала аудио в плеер...
                    tryApplyPendingRestore()
                    loadedPageCount = batchEnd       // ...потом показываем страницы (в синхроне)
                    let isLastBatch = batchEnd >= totalPageCount
                    saveCache(allSentences, loaded: batchEnd, force: isLastBatch)
                    batchStart = batchEnd
                }

                ocrProgress = nil
                isLoadingRemainingPages = false
                speech.isFullyLoaded = true
                if allSentences.isEmpty {
                    loadError = "Не удалось распознать текст на страницах."
                }
            }
        }
    }

    // MARK: - Смешанный путь

    /// Обрабатывает документ со страницами разных типов (.text/.ocr) в порядке
    /// их номеров. Порядок предложений в speech.sentences всегда соответствует порядку
    /// страниц — иначе подсветка и навигация ломаются.
    ///
    /// TODO §3.6: Конкурентный OCR-lane (параллельная обработка OCR-страниц с последующей
    /// сборкой в правильном порядке) — бэклог. Сейчас обработка строго последовательна.
    private func loadMixed(_ doc: PDFDocument, extractionDoc: PDFDocument, cached: SentenceCacheEntry?) {
        let pageCount = doc.pageCount
        let fileName = item.fileName

        if let cached {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                startBackgroundMixedLoading(doc: doc, extractionDoc: extractionDoc,
                                            from: cached.loadedPageCount,
                                            totalPageCount: pageCount, prior: sentences)
            } else {
                speech.isFullyLoaded = true
            }
            return
        }

        // Первые ~15 страниц — быстрый старт.
        let initialCount = min(15, pageCount)
        let kinds = pageKinds

        backgroundTask = Task { [weak self] in
            let initial = await self?.processMixedPages(extractionDoc: extractionDoc, pageRange: 0..<initialCount,
                                                        kinds: kinds, boilerplate: nil) ?? []

            guard !Task.isCancelled, let self else { return }
            self.document = doc
            self.loadedPageCount = initialCount
            if initial.isEmpty && initialCount == pageCount {
                self.loadError = "Не удалось распознать текст на страницах."
                return
            }
            self.finishLoading(initial)
            SentencePageCache.save(sentences: initial, loadedPageCount: initialCount,
                                   totalPageCount: pageCount, for: fileName)

            guard initialCount < pageCount else {
                self.speech.isFullyLoaded = true
                return
            }
            self.isLoadingRemainingPages = true
            self.startBackgroundMixedLoading(doc: doc, extractionDoc: extractionDoc, from: initialCount,
                                             totalPageCount: pageCount, prior: initial)
        }
    }

    private func startBackgroundMixedLoading(doc: PDFDocument, extractionDoc: PDFDocument, from startPage: Int,
                                             totalPageCount: Int, prior: [Sentence]) {
        backgroundTask?.cancel()
        let fileName = item.fileName
        let kinds = pageKinds

        backgroundTask = Task { [weak self] in
            var allSentences = prior
            // OCR медленный — батчи меньше чем для текстового пути.
            let batchSize = 10
            var batchStart = startPage

            while batchStart < totalPageCount {
                // Отменённый таск (закрытие сессии/удаление книги) не должен
                // пересоздавать кэш удалённой/закрытой книги — выходим без сохранения.
                guard !Task.isCancelled else { return }

                let batchEnd = min(batchStart + batchSize, totalPageCount)
                let batch = await self?.processMixedPages(extractionDoc: extractionDoc, pageRange: batchStart..<batchEnd,
                                                           kinds: kinds, boilerplate: nil) ?? []

                guard !Task.isCancelled, let self else { return }
                allSentences.append(contentsOf: batch)
                self.speech.appendSentences(batch)
                self.tryApplyPendingRestore()
                self.loadedPageCount = batchEnd

                let snap = allSentences
                Task.detached(priority: .background) {
                    SentencePageCache.save(sentences: snap, loadedPageCount: batchEnd,
                                          totalPageCount: totalPageCount, for: fileName)
                }

                batchStart = batchEnd
            }

            guard !Task.isCancelled, let self else { return }
            self.speech.isFullyLoaded = true
            self.isLoadingRemainingPages = false
        }
    }

    /// Обрабатывает диапазон страниц смешанного документа строго по порядку.
    /// Текстовые страницы — через PDFTextExtractor, OCR-страницы — через OCRTextExtractor
    /// по одной (pageRange pi..<pi+1). Результат возвращается в порядке страниц.
    ///
    /// `boilerplate` передаётся nil → вычисляется по текстовым строкам текущего батча.
    /// Точность детекта колонтитулов ниже чем при полном документе — приемлемо для
    /// смешанного режима, где страниц текстового слоя может быть мало.
    ///
    /// `extractionDoc` — ВСЕГДА фоновая копия документа (не main-`document`),
    /// вызывается только из фоновых Task/Task.detached путей.
    private func processMixedPages(extractionDoc: PDFDocument,
                                   pageRange: Range<Int>,
                                   kinds: [PageKind],
                                   boilerplate: Set<String>?) async -> [Sentence] {
        var result: [Sentence] = []
        // Локальная копия для Task.detached (вне главного актора).
        let profile = profile

        // Собираем boilerplate по текстовым страницам батча, если не передан снаружи.
        // Оконный детект + объединение с уже накопленным (T5, `boilerplateKeys`) —
        // раньше каждый батч по 10 страниц считал колонтитулы плоским детектом с
        // нуля, независимо от остальных фаз загрузки, и результат «плавал».
        let effectiveBoilerplate: Set<String>
        if let bp = boilerplate {
            effectiveBoilerplate = bp
        } else {
            let textLines: [[TextPipeline.PageLine]] = pageRange.map { pi in
                guard pi < kinds.count, kinds[pi] == .text else { return [] }
                return TextPipeline.lines(of: extractionDoc.page(at: pi)?.string ?? "")
            }
            let windowed = await Task.detached(priority: .background) {
                TextPipeline.detectBoilerplateWindowed(pages: textLines)
            }.value
            boilerplateKeys.formUnion(windowed)
            effectiveBoilerplate = boilerplateKeys
        }

        for pi in pageRange {
            guard pi < kinds.count else { continue }
            switch kinds[pi] {
            case .text:
                let lines = TextPipeline.lines(of: extractionDoc.page(at: pi)?.string ?? "")
                guard !lines.isEmpty else { continue }
                // Извлекаем предложения одной страницы через общий конвейер.
                let pageSentences = await Task.detached(priority: .background) {
                    PDFTextExtractor.extractSentences(
                        pageRange: 0..<1,
                        allLines: [lines],
                        boilerplate: effectiveBoilerplate,
                        pageOffset: pi,
                        profile: profile
                    )
                }.value
                result.append(contentsOf: pageSentences)

            case .ocr:
                // Ленивый blank-чек: рендерим thumbnail только здесь, off-main, прямо перед OCR.
                // На этапе load() мы намеренно его пропустили, чтобы не рендерить 720 страниц
                // пачкой на main thread. Общий хелпер — тот же чек теперь встроен и в
                // `OCRTextExtractor.sentences` (единственная точка для чисто-OCR пути `runOCR`,
                // у которого нет собственного постраничного цикла); здесь он избыточен, но
                // безвреден и экономит один лишний `await` до вызова экстрактора.
                guard let page = extractionDoc.page(at: pi) else { continue }
                let blank = await isPageBlank(page)
                guard !blank else { continue }

                let pageSentences = await OCRTextExtractor.sentences(
                    from: extractionDoc,
                    pageRange: pi..<(pi + 1),
                    profile: profile
                ) { _, _ in }
                result.append(contentsOf: pageSentences)
            }
        }

        return result
    }

    private func finishLoading(_ sentences: [Sentence]) {
        // Подстраховка для книг, извлечённых ДО появления детекта: предложения
        // пришли из кэша, образец брать было неоткуда. Берём его из самих
        // предложений — язык попадёт в библиотеку и выберет верный голос.
        // Заголовки в таком кэше останутся определёнными старым профилем: ради
        // них перестраивать готовый кэш дороже, чем оно того стоит.
        if needsLanguageDetection, !sentences.isEmpty {
            let sample = sentences.prefix(80).map(\.rawText).joined(separator: " ")
            resolveLanguage(from: sample)
        }
        if isReflowable {
            let n = bookContent?.chapters.count ?? 0
            // Для каждого ch ищем первый индекс предложения где s.pageIndex == ch.
            // Пустым главам выставляем ближайшую следующую позицию (backward pass).
            var mapping = [Int](repeating: 0, count: n)
            var found   = [Bool](repeating: false, count: n)
            for (idx, s) in sentences.enumerated() {
                let ch = s.pageIndex
                if ch < n && !found[ch] {
                    mapping[ch] = idx
                    found[ch] = true
                }
            }
            var fallback = sentences.isEmpty ? 0 : sentences.count - 1
            for i in stride(from: n - 1, through: 0, by: -1) {
                if !found[i] { mapping[i] = fallback }
                else { fallback = mapping[i] }
            }
            chapterFirstSentence = mapping
        }
        // Сохранённая позиция может быть дальше, чем этот (первый) батч
        // предложений — SpeechEngine.load клампит startIndex по нему.
        // Запоминаем цель, чтобы восстановить её, когда фоновая загрузка
        // догонит (см. tryApplyPendingRestore).
        pendingRestoreIndex = item.currentSentenceIndex >= sentences.count
            ? item.currentSentenceIndex : nil
        speech.load(sentences: sentences, startIndex: item.currentSentenceIndex)
        nowPlaying = NowPlayingController(speech: speech, title: item.title)
    }

    /// Пытается применить отложенное восстановление позиции после того, как в
    /// очередь добавился очередной батч предложений. Если пользователь уже сам
    /// нажал play/выбрал место — не перетираем его текущую позицию, просто
    /// снимаем отметку (он и так слушает там, где сам решил).
    private func tryApplyPendingRestore() {
        guard let target = pendingRestoreIndex, target < speech.sentences.count else { return }
        if !speech.isSpeaking {
            speech.seekSilent(to: target)
        }
        pendingRestoreIndex = nil
    }

    func togglePlayPause() { speech.togglePlayPause() }

    /// Явно фиксирует прогресс в хранилище. Обычно позиция и так актуальна
    /// (`speech.onIndexChange` сохраняет её на СТАРТЕ каждого предложения), но
    /// это событие подтягивается только по мере воспроизведения — перед
    /// остановкой сессии (✕ в мини-плеере) фиксируем currentIndex напрямую,
    /// чтобы не зависеть от того, придёт ли ещё одно такое событие.
    ///
    /// `updateProgress` копит позицию в памяти (дебаунс — см. `DocumentStore`);
    /// здесь дополнительно форсируем немедленный `flushProgress`, иначе
    /// последняя позиция дожидалась бы таймера, а сессия уже закрывается.
    private func persistProgress() {
        guard let store else { return }
        store.updateProgress(for: item.id, sentenceIndex: speech.currentIndex)
        store.flushProgress()
    }

    /// Полное закрытие сессии чтения (✕ в мини-плеере, открытие другой книги,
    /// удаление книги) — НЕ вызывается на простом уходе с экрана читалки, где
    /// чтение продолжается в фоне через мини-плеер (см. `PlaybackCoordinator`,
    /// который вызывает этот метод только при реальной смене/остановке сессии).
    func endSession() {
        backgroundTask?.cancel()
        backgroundTask = nil
        persistProgress()
        speech.shutdown()
        nowPlaying?.teardown()
        nowPlaying = nil
    }

    // MARK: - Закладки

    /// Добавляет закладку на КОНКРЕТНОЕ предложение (тап «пузырёк» → кнопка
    /// закладки). Возвращает false, если такая закладка уже есть или индекс
    /// невалиден — вызов не дублирует закладки на одно и то же место.
    @discardableResult
    func addBookmark(atSentence index: Int) -> Bool {
        guard speech.sentences.indices.contains(index) else { return false }
        guard !bookmarks.contains(where: { $0.sentenceIndex == index }) else { return false }
        let sentence = speech.sentences[index]
        let bm = Bookmark(sentenceIndex: index,
                          pageIndex: sentence.pageIndex,
                          preview: String(sentence.rawText.prefix(80)))
        store?.addBookmark(bm, to: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
        return true
    }

    func removeBookmark(_ bm: Bookmark) {
        store?.removeBookmark(id: bm.id, from: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
    }

    /// Перейти к закладке, сохранив play/pause (как переход по главе).
    func navigate(to bm: Bookmark) {
        clearPendingRestore()
        speech.seek(to: bm.sentenceIndex)
    }
}
