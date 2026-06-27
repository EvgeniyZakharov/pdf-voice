import AVFoundation
import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var settings: SettingsStore
    @StateObject private var model: ReaderViewModel

    @State private var pendingIndex: Int?
    @State private var tapPoint: CGPoint = .zero
    @State private var currentPage = 0
    @State private var scrubValue: Double = 1
    @State private var isScrubbing = false
    @State private var pageJump: PageJump?
    @State private var jumpToken = 0
    @State private var showThumbnails = false
    @State private var showBookmarks = false

    init(item: LibraryItem) {
        _model = StateObject(wrappedValue: ReaderViewModel(item: item, store: nil))
    }

    /// Скраббер и pageBar работают по числу готовых страниц.
    private var pageCount: Int { model.loadedPageCount }

    /// Аудио готово к воспроизведению — есть хотя бы одно предложение.
    /// То же условие, по которому активна кнопка Play. Пока false — показываем
    /// экран подготовки, а НЕ читаемую страницу с мёртвой кнопкой.
    private var audioReady: Bool { !model.speech.sentences.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            content
            if audioReady {
                if pageCount > 1 {
                    Divider()
                    pageBar
                }
                Divider()
                PlayerControls(model: model)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showThumbnails) {
            if let document = model.document {
                ThumbnailGridView(document: document,
                                  currentPage: currentPage,
                                  readyPageCount: model.loadedPageCount) { requestJump(to: $0) }
            }
        }
        .sheet(isPresented: $showBookmarks) {
            BookmarksView(model: model)
        }
        .onAppear {
            model.attach(store: store)
            model.applySettings(settings)
            model.load()
            settings.probeSilero()
        }
        .onDisappear { model.endSession() }
        .onChange(of: settings.selectedVoice)      { _ in model.applySettings(settings) }
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Закладки — открывает список; добавление через + внутри листа
            let hasBookmarkOnPage = model.bookmarks.contains(where: { $0.pageIndex == currentPage })
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: hasBookmarkOnPage ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(hasBookmarkOnPage ? Theme.accent : Color.primary)
            }
        }
    }

    // MARK: - Навигация по страницам

    private var pageBar: some View {
        HStack(spacing: 14) {
            Button { showThumbnails = true } label: {
                Image(systemName: "square.grid.2x2").font(.body)
            }
            Slider(value: $scrubValue, in: 1...Double(max(pageCount, 1)), step: 1) { editing in
                isScrubbing = editing
                if !editing { requestJump(to: Int(scrubValue) - 1) }
            }
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(scrubValue))/\(pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.totalPages > pageCount {
                    Text("из \(model.totalPages)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 56, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onChange(of: scrubValue) { value in
            if isScrubbing { requestJump(to: Int(value) - 1) }
        }
        .onChange(of: currentPage) { page in
            if !isScrubbing { scrubValue = Double(page + 1) }
        }
    }

    private func requestJump(to page: Int) {
        let clamped = max(0, min(page, max(pageCount - 1, 0)))
        jumpToken += 1
        pageJump = PageJump(page: clamped, token: jumpToken)
        // Двигаем источник истины сразу: при программном go(to:) нотификация
        // .PDFViewPageChanged приходит ненадёжно/с задержкой, иначе скраббер
        // «отстаёт» до ручного скролла. onChange(of: currentPage) сам учитывает
        // isScrubbing, так что значение слайдера при перетаскивании не перебьётся.
        currentPage = clamped
    }

    // MARK: - Контент PDF

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            infoMessage(icon: "exclamationmark.triangle", text: error)
        } else if audioReady {
            if model.isReflowable {
                reflowContent
            } else {
                pdfContent
            }
        } else {
            preparingView
        }
    }

    // MARK: - Контент reflow (TXT/FB2/EPUB/DOCX)

    private var reflowContent: some View {
        ZStack(alignment: .topLeading) {
            ReflowReaderView(text: model.reflowFlatText,
                             chapterOffsets: model.reflowChapterOffsets,
                             highlight: model.currentSentence,
                             sentences: model.speech.sentences,
                             onTap: { index, point in
                                 if let index {
                                     tapPoint = point
                                     withAnimation(.easeOut(duration: 0.12)) { pendingIndex = index }
                                 } else {
                                     withAnimation(.easeOut(duration: 0.12)) { pendingIndex = nil }
                                 }
                             })
                .compositingGroup()
                .overlay(
                    Theme.pageBackground
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                )

            if let index = pendingIndex {
                playHereBubble(for: index)
                    .position(x: tapPoint.x, y: max(tapPoint.y - 44, 28))
                    .transition(.scale.combined(with: .opacity))
            }
        }
    }

    // MARK: - Контент PDF

    @ViewBuilder
    private var pdfContent: some View {
            ZStack(alignment: .topLeading) {
                PDFKitView(document: model.displayDocument,
                           readyPageCount: model.loadedPageCount,
                           highlight: model.currentSentence,
                           sentences: model.speech.sentences,
                           pageJump: pageJump,
                           onTap: { index, point in
                               if let index {
                                   tapPoint = point
                                   withAnimation(.easeOut(duration: 0.12)) { pendingIndex = index }
                               } else {
                                   withAnimation(.easeOut(duration: 0.12)) { pendingIndex = nil }
                               }
                           },
                           onPageChange: { page in
                               currentPage = page
                               model.updateVisiblePage(page)
                           })
                    // Тёплая «бумага»: multiply тонирует белые страницы в крем,
                    // чёрный текст остаётся читаемым. compositingGroup ограничивает
                    // смешивание самим PDF.
                    .compositingGroup()
                    .overlay(
                        Theme.pageBackground
                            .blendMode(.multiply)
                            .allowsHitTesting(false)
                    )

                if let index = pendingIndex {
                    playHereBubble(for: index)
                        .position(x: tapPoint.x, y: max(tapPoint.y - 44, 28))
                        .transition(.scale.combined(with: .opacity))
                }

                if let progress = model.ocrProgress {
                    ocrProgressBanner(progress)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
    }

    /// Экран подготовки: показывается, пока аудио не готово (нет предложений).
    /// Скрывает читаемую страницу, чтобы не создавать ложного впечатления готовности.
    private var preparingView: some View {
        VStack(spacing: 16) {
            if let progress = model.ocrProgress {
                ProgressView(value: progress)
                    .frame(maxWidth: 220)
                Text("Распознаём текст… \(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Скан без текстового слоя — готовим озвучку")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ProgressView()
                Text("Готовим озвучку…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    // MARK: - Вспомогательные вью

    private func playHereBubble(for index: Int) -> some View {
        Button {
            model.speech.play(from: index)
            withAnimation(.easeOut(duration: 0.12)) { pendingIndex = nil }
        } label: {
            Label("Отсюда", systemImage: "play.fill")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Theme.accent, in: Capsule())
                .foregroundStyle(Theme.onAccent)
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func ocrProgressBanner(_ progress: Double) -> some View {
        VStack(spacing: 6) {
            ProgressView(value: progress)
            Text("Распознаём текст… \(Int(progress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func infoMessage(icon: String, text: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Статические хелперы (используются SettingsView)

    static func speedLabel(_ value: Double) -> String {
        let str = value == value.rounded() ? String(Int(value)) : String(value)
        return str + "×"
    }
}

// MARK: - Панель плеера

private struct PlayerControls: View {
    @ObservedObject var model: ReaderViewModel
    @ObservedObject private var speech: SpeechEngine

    init(model: ReaderViewModel) {
        _model = ObservedObject(wrappedValue: model)
        _speech = ObservedObject(wrappedValue: model.speech)
    }

    var body: some View {
        // Транспорт (пред. / play / след. предложение) по центру, скорость слева.
        ZStack {
            HStack(spacing: 24) {
                Button { speech.skipBackward() } label: {
                    Image(systemName: "gobackward")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                }
                Button { model.togglePlayPause() } label: {
                    Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 62, height: 62)
                        .background(Theme.accent, in: Circle())
                        .shadow(color: Theme.accent.opacity(0.25), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
                Button { speech.skipForward() } label: {
                    Image(systemName: "goforward")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.accent)
                }
            }
            HStack {
                speedMenu
                Spacer()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .disabled(speech.sentences.isEmpty)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(SpeechEngine.speedOptions, id: \.self) { option in
                Button {
                    speech.speed = option
                } label: {
                    if speech.speed == option {
                        Label(ReaderView.speedLabel(option), systemImage: "checkmark")
                    } else {
                        Text(ReaderView.speedLabel(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "speedometer")
                Text(ReaderView.speedLabel(speech.speed))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Theme.accent.opacity(0.10), in: Capsule())
        }
    }
}
