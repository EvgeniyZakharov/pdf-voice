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
    @Published private(set) var currentVisiblePage: Int = 0
    @Published private(set) var isLoadingRemainingPages = false
    @Published private(set) var loadedPageCount: Int = 0

    let speech = SpeechEngine()
    let sleepTimer = SleepTimer()

    private let item: LibraryItem
    private weak var store: DocumentStore?
    private var cancellables = Set<AnyCancellable>()
    private var nowPlaying: NowPlayingController?
    private var totalPageCount: Int = 0
    private var backgroundTask: Task<Void, Never>?

    // Тип документа, устанавливается при load() однократно.
    private enum DocumentMode { case text, ocr, mixed }
    private var documentMode: DocumentMode = .text

    // Постраничная классификация для смешанного режима.
    private var pageKinds: [PageKind] = []

    init(item: LibraryItem, store: DocumentStore?) {
        self.item = item
        self.store = store
        speech.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
        sleepTimer.onExpire = { [weak self] in self?.speech.pause() }
    }

    func attach(store: DocumentStore) {
        self.store = store
        bookmarks = store.items.first(where: { $0.id == item.id })?.bookmarks ?? []
        speech.onIndexChange = { [weak self] index in
            guard let self else { return }
            self.store?.updateProgress(for: self.item.id, sentenceIndex: index)
        }
    }

    func applySettings(_ settings: SettingsStore) {
        speech.speed = settings.speed
        speech.pauseBetweenSentences = settings.pauseBetweenSentences
        speech.sileroAPIKey = settings.sileroAPIKey

        let sel = settings.selectedVoice
        if sel.hasPrefix("silero:"), !settings.sileroServerURL.isEmpty {
            speech.sileroServerURL = URL(string: settings.sileroServerURL)
            speech.sileroSpeaker = String(sel.dropFirst("silero:".count))
        } else {
            // Системный голос (или откат на него, если Silero недоступен).
            speech.sileroServerURL = nil
            let id = sel.hasPrefix("sys:") ? String(sel.dropFirst("sys:".count)) : sel
            if let v = AVSpeechSynthesisVoice(identifier: id) { speech.voice = v }
        }
    }

    // MARK: - Состояние для UI

    var currentSentence: Sentence? {
        guard speech.sentences.indices.contains(speech.currentIndex) else { return nil }
        return speech.sentences[speech.currentIndex]
    }

    var currentSentenceText: String { currentSentence?.rawText ?? "" }

    func updateVisiblePage(_ page: Int) { currentVisiblePage = page }

    // MARK: - Загрузка

    func load() {
        guard let doc = PDFDocument(url: item.fileURL) else {
            loadError = "Не удалось открыть PDF."
            return
        }
        totalPageCount = doc.pageCount

        // Дешёвая классификация — только плотность букв (page.string), без рендера thumbnail.
        // textDensityKind возвращает только .text или .ocr; .skip не выставляется здесь.
        var kinds: [PageKind] = []
        kinds.reserveCapacity(doc.pageCount)
        for pi in 0..<doc.pageCount {
            if let page = doc.page(at: pi) {
                kinds.append(textDensityKind(page))
            } else {
                kinds.append(.ocr)
            }
        }
        pageKinds = kinds

        let hasText = kinds.contains(.text)
        let hasOCR  = kinds.contains(.ocr)

        switch (hasText, hasOCR) {
        case (true, false):
            // Чисто текстовый — проверенный путь без изменений.
            documentMode = .text
            loadText(doc)
        case (false, _):
            // Чисто OCR — проверенный путь без изменений.
            documentMode = .ocr
            loadOCR(doc)
        default:
            // Смешанный: часть страниц с текстовым слоем, часть — сканы.
            documentMode = .mixed
            loadMixed(doc)
        }
    }

    // MARK: - Чисто текстовый путь (без изменений)

    private func loadText(_ doc: PDFDocument) {
        let pageCount = doc.pageCount

        if let cached = SentencePageCache.load(for: item.fileName) {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                startBackgroundTextLoading(doc: doc, from: cached.loadedPageCount,
                                           totalPageCount: pageCount, prior: sentences)
            }
            return
        }

        if pageCount <= 20 {
            let sentences = PDFTextExtractor.sentences(from: doc)
            document = doc
            loadedPageCount = pageCount
            finishLoading(sentences)
            SentencePageCache.save(sentences: sentences, loadedPageCount: pageCount,
                                   totalPageCount: pageCount, for: item.fileName)
            return
        }

        loadTextProgressively(doc)
    }

    private func loadTextProgressively(_ doc: PDFDocument) {
        let pageCount = doc.pageCount
        let initialCount = min(15, pageCount)
        let initialLines: [[TextPipeline.PageLine]] = (0..<initialCount).map {
            TextPipeline.lines(of: doc.page(at: $0)?.string ?? "")
        }
        let quickBoilerplate = TextPipeline.detectBoilerplate(
            pages: initialLines, pageCount: initialCount
        )
        let savedIndex = item.currentSentenceIndex
        let fileName = item.fileName

        Task {
            let initial = await Task.detached(priority: .userInitiated) {
                PDFTextExtractor.extractSentences(
                    pageRange: 0..<initialCount,
                    allLines: initialLines,
                    boilerplate: quickBoilerplate
                )
            }.value

            document = doc
            loadedPageCount = initialCount
            finishLoading(initial)
            SentencePageCache.save(sentences: initial, loadedPageCount: initialCount,
                                   totalPageCount: pageCount, for: fileName)

            guard initialCount < pageCount else { return }
            isLoadingRemainingPages = true
            startBackgroundTextLoading(doc: doc, from: initialCount,
                                       totalPageCount: pageCount, prior: initial)

            if savedIndex >= initial.count, savedIndex < speech.sentences.count, !speech.isSpeaking {
                speech.seekSilent(to: savedIndex)
            }
        }
    }

    private func startBackgroundTextLoading(doc: PDFDocument, from startPage: Int,
                                            totalPageCount: Int, prior: [Sentence]) {
        backgroundTask?.cancel()
        let fileName = item.fileName
        let savedIndex = item.currentSentenceIndex

        backgroundTask = Task {
            // Читаем строки страниц off main thread через GCD.
            let remainingLines: [[TextPipeline.PageLine]] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .background).async {
                    var lines: [[TextPipeline.PageLine]] = []
                    lines.reserveCapacity(totalPageCount - startPage)
                    for pi in startPage..<totalPageCount {
                        lines.append(TextPipeline.lines(of: doc.page(at: pi)?.string ?? ""))
                    }
                    cont.resume(returning: lines)
                }
            }

            guard !Task.isCancelled else { return }

            // Детект boilerplate off main thread.
            let boilerplate = await Task.detached(priority: .background) {
                TextPipeline.detectBoilerplate(pages: remainingLines, pageCount: remainingLines.count)
            }.value

            var allSentences = prior
            let batchSize = 50
            var batchStart = 0

            while batchStart < remainingLines.count {
                if Task.isCancelled {
                    let snap = allSentences; let loaded = startPage + batchStart
                    Task.detached(priority: .background) {
                        SentencePageCache.save(sentences: snap, loadedPageCount: loaded,
                                              totalPageCount: totalPageCount, for: fileName)
                    }
                    return
                }

                let batchEnd = min(batchStart + batchSize, remainingLines.count)

                // Извлечение предложений off main thread.
                let batch = await Task.detached(priority: .background) {
                    PDFTextExtractor.extractSentences(
                        pageRange: batchStart..<batchEnd,
                        allLines: remainingLines,
                        boilerplate: boilerplate,
                        pageOffset: startPage
                    )
                }.value

                allSentences.append(contentsOf: batch)
                speech.appendSentences(batch)
                loadedPageCount = startPage + batchEnd

                // Сохранение off main thread — не блокируем UI.
                let snap = allSentences; let loaded = startPage + batchEnd
                Task.detached(priority: .background) {
                    SentencePageCache.save(sentences: snap, loadedPageCount: loaded,
                                          totalPageCount: totalPageCount, for: fileName)
                }

                batchStart = batchEnd
            }

            // Восстанавливаем позицию если она была за пределами начального батча.
            if savedIndex >= prior.count, savedIndex < speech.sentences.count, !speech.isSpeaking {
                speech.seekSilent(to: savedIndex)
            }
            isLoadingRemainingPages = false
        }
    }

    // MARK: - Чисто OCR путь (без изменений)

    private func loadOCR(_ doc: PDFDocument) {
        let pageCount = doc.pageCount

        if let cached = SentencePageCache.load(for: item.fileName) {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                runOCR(doc: doc, from: cached.loadedPageCount,
                       totalPageCount: pageCount, prior: sentences)
            }
            return
        }

        document = doc
        runOCR(doc: doc, from: 0, totalPageCount: pageCount, prior: [])
    }

    private func runOCR(doc: PDFDocument, from startPage: Int,
                        totalPageCount: Int, prior: [Sentence]) {
        ocrProgress = Double(startPage) / Double(totalPageCount)
        let fileName = item.fileName

        Task {
            let initialCount = min(startPage + 15, totalPageCount)

            if startPage < initialCount {
                let initial = await OCRTextExtractor.sentences(
                    from: doc,
                    pageRange: startPage..<initialCount
                ) { [weak self] done, total in
                    let overall = Double(startPage + done) / Double(totalPageCount)
                    self?.ocrProgress = overall * 0.2
                }

                let allInitial = prior + initial
                if !prior.isEmpty || !initial.isEmpty {
                    if prior.isEmpty {
                        finishLoading(allInitial)
                    } else {
                        speech.appendSentences(initial)
                    }
                    loadedPageCount = initialCount
                    SentencePageCache.save(sentences: allInitial,
                                          loadedPageCount: initialCount,
                                          totalPageCount: totalPageCount, for: fileName)
                }

                guard initialCount < totalPageCount else {
                    ocrProgress = nil
                    isLoadingRemainingPages = false
                    if allInitial.isEmpty {
                        loadError = "Не удалось распознать текст на страницах."
                    }
                    return
                }

                isLoadingRemainingPages = true

                var allSentences = allInitial
                let rest = await OCRTextExtractor.sentences(
                    from: doc,
                    pageRange: initialCount..<totalPageCount
                ) { [weak self] done, total in
                    let overall = 0.2 + Double(initialCount + done) / Double(totalPageCount)
                    self?.ocrProgress = min(overall, 0.99)
                    self?.loadedPageCount = initialCount + done
                }

                ocrProgress = nil
                allSentences.append(contentsOf: rest)

                if allSentences.isEmpty {
                    loadError = "Не удалось распознать текст на страницах."
                } else {
                    SentencePageCache.save(sentences: allSentences,
                                          loadedPageCount: totalPageCount,
                                          totalPageCount: totalPageCount, for: fileName)
                    speech.appendSentences(rest)
                    loadedPageCount = totalPageCount
                    isLoadingRemainingPages = false
                }
            }
        }
    }

    // MARK: - Смешанный путь

    /// Обрабатывает документ со страницами разных типов (.text/.ocr/.skip) в порядке
    /// их номеров. Порядок предложений в speech.sentences всегда соответствует порядку
    /// страниц — иначе подсветка и навигация ломаются.
    ///
    /// TODO §3.6: Конкурентный OCR-lane (параллельная обработка OCR-страниц с последующей
    /// сборкой в правильном порядке) — бэклог. Сейчас обработка строго последовательна.
    private func loadMixed(_ doc: PDFDocument) {
        let pageCount = doc.pageCount
        let fileName = item.fileName

        if let cached = SentencePageCache.load(for: item.fileName) {
            let sentences = cached.entries.map { $0.toSentence() }
            document = doc
            loadedPageCount = min(cached.loadedPageCount, pageCount)
            finishLoading(sentences)

            if !cached.isComplete && cached.loadedPageCount < pageCount {
                isLoadingRemainingPages = true
                startBackgroundMixedLoading(doc: doc, from: cached.loadedPageCount,
                                            totalPageCount: pageCount, prior: sentences)
            }
            return
        }

        // Первые ~15 страниц — быстрый старт.
        let initialCount = min(15, pageCount)
        let kinds = pageKinds

        Task {
            let initial = await processMixedPages(doc: doc, pageRange: 0..<initialCount,
                                                  kinds: kinds, boilerplate: nil)

            document = doc
            loadedPageCount = initialCount
            if initial.isEmpty && initialCount == pageCount {
                loadError = "Не удалось распознать текст на страницах."
                return
            }
            finishLoading(initial)
            SentencePageCache.save(sentences: initial, loadedPageCount: initialCount,
                                   totalPageCount: pageCount, for: fileName)

            guard initialCount < pageCount else { return }
            isLoadingRemainingPages = true
            startBackgroundMixedLoading(doc: doc, from: initialCount,
                                        totalPageCount: pageCount, prior: initial)

            let savedIndex = item.currentSentenceIndex
            if savedIndex >= initial.count, savedIndex < speech.sentences.count, !speech.isSpeaking {
                speech.seekSilent(to: savedIndex)
            }
        }
    }

    private func startBackgroundMixedLoading(doc: PDFDocument, from startPage: Int,
                                             totalPageCount: Int, prior: [Sentence]) {
        backgroundTask?.cancel()
        let fileName = item.fileName
        let savedIndex = item.currentSentenceIndex
        let kinds = pageKinds

        backgroundTask = Task {
            var allSentences = prior
            // OCR медленный — батчи меньше чем для текстового пути.
            let batchSize = 10
            var batchStart = startPage

            while batchStart < totalPageCount {
                if Task.isCancelled {
                    let snap = allSentences
                    Task.detached(priority: .background) {
                        SentencePageCache.save(sentences: snap, loadedPageCount: batchStart,
                                              totalPageCount: totalPageCount, for: fileName)
                    }
                    return
                }

                let batchEnd = min(batchStart + batchSize, totalPageCount)
                let batch = await processMixedPages(doc: doc, pageRange: batchStart..<batchEnd,
                                                    kinds: kinds, boilerplate: nil)

                allSentences.append(contentsOf: batch)
                speech.appendSentences(batch)
                loadedPageCount = batchEnd

                let snap = allSentences
                Task.detached(priority: .background) {
                    SentencePageCache.save(sentences: snap, loadedPageCount: batchEnd,
                                          totalPageCount: totalPageCount, for: fileName)
                }

                batchStart = batchEnd
            }

            if savedIndex >= prior.count, savedIndex < speech.sentences.count, !speech.isSpeaking {
                speech.seekSilent(to: savedIndex)
            }
            isLoadingRemainingPages = false
        }
    }

    /// Обрабатывает диапазон страниц смешанного документа строго по порядку.
    /// Текстовые страницы — через PDFTextExtractor, OCR-страницы — через OCRTextExtractor
    /// по одной (pageRange pi..<pi+1). .skip пропускаются. Результат возвращается
    /// в порядке страниц.
    ///
    /// `boilerplate` передаётся nil → вычисляется по текстовым строкам текущего батча.
    /// Точность детекта колонтитулов ниже чем при полном документе — приемлемо для
    /// смешанного режима, где страниц текстового слоя может быть мало.
    private func processMixedPages(doc: PDFDocument,
                                   pageRange: Range<Int>,
                                   kinds: [PageKind],
                                   boilerplate: Set<String>?) async -> [Sentence] {
        var result: [Sentence] = []

        // Собираем boilerplate по текстовым страницам батча, если не передан снаружи.
        let effectiveBoilerplate: Set<String>
        if let bp = boilerplate {
            effectiveBoilerplate = bp
        } else {
            let textLines: [[TextPipeline.PageLine]] = pageRange.map { pi in
                guard pi < kinds.count, kinds[pi] == .text else { return [] }
                return TextPipeline.lines(of: doc.page(at: pi)?.string ?? "")
            }
            effectiveBoilerplate = await Task.detached(priority: .background) {
                TextPipeline.detectBoilerplate(pages: textLines, pageCount: textLines.count)
            }.value
        }

        for pi in pageRange {
            guard pi < kinds.count else { continue }
            switch kinds[pi] {
            case .skip:
                continue

            case .text:
                let lines = TextPipeline.lines(of: doc.page(at: pi)?.string ?? "")
                guard !lines.isEmpty else { continue }
                // Извлекаем предложения одной страницы через общий конвейер.
                let pageSentences = await Task.detached(priority: .background) {
                    PDFTextExtractor.extractSentences(
                        pageRange: 0..<1,
                        allLines: [lines],
                        boilerplate: effectiveBoilerplate,
                        pageOffset: pi
                    )
                }.value
                result.append(contentsOf: pageSentences)

            case .ocr:
                // Ленивый blank-чек: рендерим thumbnail только здесь, off-main, прямо перед OCR.
                // На этапе load() мы намеренно его пропустили, чтобы не рендерить 720 страниц
                // пачкой на main thread.
                guard let page = doc.page(at: pi) else { continue }
                let blank = await Task.detached(priority: .background) {
                    isBlankPage(page)
                }.value
                guard !blank else { continue }

                let pageSentences = await OCRTextExtractor.sentences(
                    from: doc,
                    pageRange: pi..<(pi + 1)
                ) { _, _ in }
                result.append(contentsOf: pageSentences)
            }
        }

        return result
    }

    // MARK: - Приоритетная загрузка (исправление бага: ветвление по типу документа)

    func requestPriorityLoad(pageIndex: Int) {
        guard pageIndex >= loadedPageCount, let doc = document else { return }
        backgroundTask?.cancel()
        isLoadingRemainingPages = true

        switch documentMode {
        case .text:
            startBackgroundTextLoading(doc: doc, from: loadedPageCount,
                                       totalPageCount: totalPageCount, prior: speech.sentences)
        case .ocr:
            runOCR(doc: doc, from: loadedPageCount,
                   totalPageCount: totalPageCount, prior: speech.sentences)
        case .mixed:
            startBackgroundMixedLoading(doc: doc, from: loadedPageCount,
                                        totalPageCount: totalPageCount, prior: speech.sentences)
        }
    }

    private func finishLoading(_ sentences: [Sentence]) {
        speech.load(sentences: sentences, startIndex: item.currentSentenceIndex)
        nowPlaying = NowPlayingController(speech: speech, title: item.title)
    }

    func togglePlayPause() { speech.togglePlayPause() }

    func endSession() {
        speech.pause()
        sleepTimer.cancel()
        nowPlaying?.teardown()
        nowPlaying = nil
    }

    // MARK: - Закладки

    @discardableResult
    func addBookmark() -> Bool {
        let targetSentence: Sentence?
        let targetIndex: Int

        if speech.isSpeaking {
            guard let s = currentSentence else { return false }
            targetSentence = s
            targetIndex = speech.currentIndex
        } else {
            if let idx = speech.sentences.firstIndex(where: { $0.pageIndex == currentVisiblePage }) {
                targetSentence = speech.sentences[idx]
                targetIndex = idx
            } else if let closest = speech.sentences.enumerated().min(by: {
                abs($0.element.pageIndex - currentVisiblePage) < abs($1.element.pageIndex - currentVisiblePage)
            }) {
                targetSentence = closest.element
                targetIndex = closest.offset
            } else {
                return false
            }
        }

        guard let sentence = targetSentence else { return false }
        let preview = String(sentence.rawText.prefix(80))
        let bm = Bookmark(sentenceIndex: targetIndex,
                          pageIndex: sentence.pageIndex,
                          preview: preview)
        store?.addBookmark(bm, to: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
        return true
    }

    func removeBookmark(_ bm: Bookmark) {
        store?.removeBookmark(id: bm.id, from: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
    }

    func navigate(to bm: Bookmark) {
        speech.play(from: bm.sentenceIndex)
    }
}
