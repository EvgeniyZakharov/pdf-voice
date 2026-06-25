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
    @State private var showSleepTimer = false

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
                PlayerControls(model: model, showSleepTimer: $showSleepTimer)
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
        .confirmationDialog("Таймер сна", isPresented: $showSleepTimer, titleVisibility: .visible) {
            if model.sleepTimer.isActive {
                Button("Отменить таймер (\(model.sleepTimer.remainingFormatted))", role: .destructive) {
                    model.sleepTimer.cancel()
                }
            } else {
                ForEach(SleepTimer.options, id: \.self) { min in
                    Button("\(min) мин") { model.sleepTimer.start(minutes: min) }
                }
            }
            Button("Отмена", role: .cancel) {}
        }
        .onAppear {
            model.attach(store: store)
            model.applySettings(settings)
            model.load()
            settings.probeSilero()
        }
        .onDisappear { model.endSession() }
        .onChange(of: settings.selectedVoice)      { _ in model.applySettings(settings) }
        .onChange(of: settings.sileroServerURL)    { _ in model.applySettings(settings); settings.probeSilero() }
        .onChange(of: settings.sileroAPIKey)       { _ in model.applySettings(settings) }
        .onChange(of: settings.speed)              { _ in model.applySettings(settings) }
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Таймер сна
            Button {
                showSleepTimer = true
            } label: {
                Image(systemName: model.sleepTimer.isActive ? "moon.fill" : "moon")
                    .foregroundStyle(model.sleepTimer.isActive ? Color.indigo : Color.primary)
            }
            // Закладки — открывает список; добавление через + внутри листа
            let hasBookmarkOnPage = model.bookmarks.contains(where: { $0.pageIndex == currentPage })
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: hasBookmarkOnPage ? "bookmark.fill" : "bookmark")
                    .foregroundStyle(hasBookmarkOnPage ? Color.accentColor : Color.primary)
            }
            // Голос
            voiceMenu
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
    }

    // MARK: - Контент PDF

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            infoMessage(icon: "exclamationmark.triangle", text: error)
        } else if audioReady {
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
        } else {
            preparingView
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

    // MARK: - Меню голоса

    @ViewBuilder
    private var voiceMenu: some View {
        Menu {
            Section("Системные") {
                ForEach(VoiceCatalog.systemOptions()) { opt in
                    voiceButton(opt)
                }
            }
            if settings.sileroReachable {
                Section("Silero · нейросеть") {
                    ForEach(VoiceCatalog.sileroOptions()) { opt in
                        voiceButton(opt)
                    }
                }
            }
        } label: {
            Image(systemName: "person.wave.2")
        }
    }

    private func voiceButton(_ opt: VoiceOption) -> some View {
        Button {
            settings.selectedVoice = opt.id
        } label: {
            if settings.selectedVoice == opt.id {
                Label(opt.title, systemImage: "checkmark")
            } else {
                Text(opt.title)
            }
        }
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
                .background(.tint, in: Capsule())
                .foregroundStyle(.white)
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
    @Binding var showSleepTimer: Bool
    @ObservedObject private var speech: SpeechEngine
    @ObservedObject private var sleepTimer: SleepTimer

    init(model: ReaderViewModel, showSleepTimer: Binding<Bool>) {
        _model = ObservedObject(wrappedValue: model)
        _showSleepTimer = showSleepTimer
        _speech = ObservedObject(wrappedValue: model.speech)
        _sleepTimer = ObservedObject(wrappedValue: model.sleepTimer)
    }

    var body: some View {
        VStack(spacing: 10) {
            if !model.currentSentenceText.isEmpty {
                Text(model.currentSentenceText)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(.secondary)
            }

            ZStack {
                // Транспорт по центру экрана.
                HStack(spacing: 40) {
                    Button { speech.skipBackward() } label: {
                        Image(systemName: "backward.fill").font(.title2)
                    }
                    Button { model.togglePlayPause() } label: {
                        Image(systemName: speech.isSpeaking ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 52))
                    }
                    Button { speech.skipForward() } label: {
                        Image(systemName: "forward.fill").font(.title2)
                    }
                }
                // Скорость слева, таймер сна справа — на одном уровне с play.
                HStack {
                    speedMenu
                    Spacer()
                    if sleepTimer.isActive {
                        Button { showSleepTimer = true } label: {
                            Label(sleepTimer.remainingFormatted, systemImage: "moon.fill")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.indigo)
                        }
                    }
                }
            }
        }
        .padding()
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }
}
