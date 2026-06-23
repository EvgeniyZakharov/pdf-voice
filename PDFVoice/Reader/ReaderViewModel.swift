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

    let speech = SpeechEngine()
    let sleepTimer = SleepTimer()

    private let item: LibraryItem
    private weak var store: DocumentStore?
    private var cancellables = Set<AnyCancellable>()
    private var nowPlaying: NowPlayingController?

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
        if let v = settings.preferredVoice { speech.voice = v }
        speech.speed = settings.speed
        speech.pauseBetweenSentences = settings.pauseBetweenSentences
        speech.sileroServerURL = settings.useSilero ? URL(string: settings.sileroServerURL) : nil
        speech.sileroSpeaker = settings.sileroSpeaker
    }

    // MARK: - Состояние для UI

    var currentSentence: Sentence? {
        guard speech.sentences.indices.contains(speech.currentIndex) else { return nil }
        return speech.sentences[speech.currentIndex]
    }

    var currentSentenceText: String { currentSentence?.text ?? "" }

    // MARK: - Загрузка

    func load() {
        guard let doc = PDFDocument(url: item.fileURL) else {
            loadError = "Не удалось открыть PDF."
            return
        }
        document = doc

        if PDFTextExtractor.hasTextLayer(doc) {
            finishLoading(PDFTextExtractor.sentences(from: doc))
        } else if let cached = OCRCache.load(for: item.fileName) {
            // Кеш найден — открываем мгновенно без OCR.
            finishLoading(cached)
        } else {
            runOCR(on: doc)
        }
    }

    private func runOCR(on doc: PDFDocument) {
        ocrProgress = 0
        Task {
            let sentences = await OCRTextExtractor.sentences(from: doc) { [weak self] done, total in
                self?.ocrProgress = total > 0 ? Double(done) / Double(total) : nil
            }
            ocrProgress = nil
            if sentences.isEmpty {
                loadError = "Не удалось распознать текст на страницах."
            } else {
                // Сохраняем в кеш — следующее открытие будет мгновенным.
                OCRCache.save(sentences, for: item.fileName)
                finishLoading(sentences)
            }
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

    func addBookmark() {
        guard let sentence = currentSentence else { return }
        let preview = String(sentence.text.prefix(80))
        let bm = Bookmark(sentenceIndex: speech.currentIndex,
                          pageIndex: sentence.pageIndex,
                          preview: preview)
        store?.addBookmark(bm, to: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
    }

    func removeBookmark(_ bm: Bookmark) {
        store?.removeBookmark(id: bm.id, from: item.id)
        bookmarks = store?.items.first(where: { $0.id == item.id })?.bookmarks ?? []
    }

    func navigate(to bm: Bookmark) {
        speech.play(from: bm.sentenceIndex)
    }
}
