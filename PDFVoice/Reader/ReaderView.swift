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
    // Reflow-навигация (не делим состояние с pageBar)
    @State private var showChapters = false

    // MARK: - Follow-режим (reflow)
    /// Текущая позиция скролла reflow-вьюшки (0…1); НЕ привязана к позиции озвучки.
    @State private var reflowScrollFraction = 0.0
    /// Индекс главы у верха вьюпорта (из onScroll репорта).
    @State private var reflowTopChapter = 0
    /// Инкрементируется перед каждой новой командой, чтобы updateUIView её применил.
    @State private var reflowCommandToken = 0
    /// Тегированная команда для ReflowReaderView (nil = нет активной команды).
    @State private var reflowCommand: ReflowCommand? = nil

    // MARK: - Follow-режим (PDF)
    /// Инкрементируется при необходимости вернуться к чтению в PDF-вьюшке.
    @State private var pdfReturnToken = 0

    // MARK: - Кнопка возврата (общая для reflow и PDF)
    /// Показывать полупрозрачную кнопку «Вернуться к чтению».
    @State private var showReturnButton = false
    /// Пользователь сейчас тащит reflow-слайдер — гасит обратную связь от onScroll.
    @State private var isReflowScrubbing = false

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
                if model.isReflowable {
                    Divider()
                    reflowBar
                } else if pageCount > 1 {
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
        .sheet(isPresented: $showChapters) {
            ChapterListView(model: model)
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

    // MARK: - Навигация reflow

    private var reflowBar: some View {
        HStack(spacing: 14) {
            if model.hasChapters {
                Button { showChapters = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.body)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Содержание")
            }
            // Слайдер привязан к позиции СКРОЛЛА, не к позиции озвучки.
            // Реактивный: прокручивает вид ВЖИВУЮ во время перетаскивания.
            // model.seek() НЕ вызывается: аудио переключается только по «Читать отсюда».
            Slider(value: $reflowScrollFraction, in: 0...1) { editing in
                isReflowScrubbing = editing
            }
            .accessibilityValue("\(Int(reflowScrollFraction * 100)) процентов")
            .onChange(of: reflowScrollFraction) { value in
                // Команду шлём только когда тащит пользователь — иначе обновление
                // фракции из onScroll (скролл/озвучка) ушло бы в ложную прокрутку.
                if isReflowScrubbing {
                    reflowCommandToken += 1
                    reflowCommand = .scrollToFraction(value, token: reflowCommandToken)
                }
            }

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(Int(reflowScrollFraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if model.hasChapters {
                    Text("Гл. \(reflowTopChapter + 1)/\(model.chapterCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
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

    // MARK: - Возврат к чтению

    /// Прокрутить к текущей подсветке и возобновить следование.
    private func returnToReading() {
        if model.isReflowable {
            reflowCommandToken += 1
            reflowCommand = .returnToReading(token: reflowCommandToken)
        } else {
            pdfReturnToken += 1
        }
    }

    // MARK: - Контент

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
                             },
                             onScroll: { f, ch, vis, following in
                                 // Пока юзер тащит слайдер — он источник истины, не перебиваем.
                                 if !isReflowScrubbing { reflowScrollFraction = f }
                                 reflowTopChapter = ch
                                 withAnimation { showReturnButton = !following && !vis }
                             },
                             command: reflowCommand)
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
        .overlay(alignment: .bottomTrailing) {
            returnButton
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
                       },
                       onFollowChanged: { vis, following in
                           withAnimation { showReturnButton = !following && !vis }
                       },
                       returnToReadingToken: pdfReturnToken)
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
        .overlay(alignment: .bottomTrailing) {
            returnButton
        }
    }

    // MARK: - Кнопка возврата к чтению

    /// Полупрозрачная круглая кнопка, появляющаяся когда:
    /// - следование за чтением приостановлено (!isFollowing)
    /// - текущая подсветка не видна во вьюпорте (!highlightVisible)
    @ViewBuilder
    private var returnButton: some View {
        if showReturnButton {
            Button { returnToReading() } label: {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().stroke(Theme.accent.opacity(0.5), lineWidth: 1))
                    .foregroundStyle(Theme.accent)
                    .opacity(0.85)
            }
            .accessibilityLabel("Вернуться к чтению")
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .transition(.scale.combined(with: .opacity))
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
            // После «Читать отсюда» возобновляем следование — вид должен ехать
            // за новой позицией чтения, а не оставаться там, где пользователь тапнул.
            if model.isReflowable {
                reflowCommandToken += 1
                reflowCommand = .returnToReading(token: reflowCommandToken)
            } else {
                pdfReturnToken += 1
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.subheadline.weight(.bold))
                .frame(width: 44, height: 44)
                .background(Theme.accent, in: Circle())
                .foregroundStyle(Theme.onAccent)
                .shadow(radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Читать отсюда")
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
