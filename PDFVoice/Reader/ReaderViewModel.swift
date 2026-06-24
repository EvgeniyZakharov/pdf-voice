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

    var currentSentenceText: String { currentSentence?.text ?? "" }

    func updateVisiblePage(_ page: Int) { currentVisiblePage = page }

    // MARK: - Загрузка

    func load() {
        guard let doc = PDFDocument(url: item.fileURL) else {
            loadError = "Не удалось открыть PDF."
            return
        }
        totalPageCount = doc.pageCount

        if PDFTextExtractor.hasTextLayer(doc) {
            loadText(doc)
        } else {
            loadOCR(doc)
        }
    }

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
        let initialLines: [[TextNormalizer.PageLine]] = (0..<initialCount).map {
            TextNormalizer.lines(of: doc.page(at: $0)?.string ?? "")
        }
        let quickBoilerplate = TextNormalizer.detectBoilerplate(
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
            let remainingLines: [[TextNormalizer.PageLine]] = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .background).async {
                    var lines: [[TextNormalizer.PageLine]] = []
                    lines.reserveCapacity(totalPageCount - startPage)
                    for pi in startPage..<totalPageCount {
                        lines.append(TextNormalizer.lines(of: doc.page(at: pi)?.string ?? ""))
                    }
                    cont.resume(returning: lines)
                }
            }

            guard !Task.isCancelled else { return }

            // Детект boilerplate off main thread.
            let boilerplate = await Task.detached(priority: .background) {
                TextNormalizer.detectBoilerplate(pages: remainingLines, pageCount: remainingLines.count)
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

    func requestPriorityLoad(pageIndex: Int) {
        guard pageIndex >= loadedPageCount, let doc = document else { return }
        backgroundTask?.cancel()
        isLoadingRemainingPages = true
        startBackgroundTextLoading(doc: doc, from: loadedPageCount,
                                   totalPageCount: totalPageCount, prior: speech.sentences)
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
        let preview = String(sentence.text.prefix(80))
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
