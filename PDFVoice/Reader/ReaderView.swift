import AVFoundation
import SwiftUI

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

    private var pageCount: Int { model.document?.pageCount ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            content
            if model.document != nil, pageCount > 1 {
                Divider()
                pageBar
            }
            Divider()
            PlayerControls(model: model, showSleepTimer: $showSleepTimer)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarItems }
        .sheet(isPresented: $showThumbnails) {
            if let document = model.document {
                ThumbnailGridView(document: document, currentPage: currentPage) { requestJump(to: $0) }
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
        }
        .onDisappear { model.endSession() }
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
            // Закладка
            Button {
                model.addBookmark()
            } label: {
                Image(systemName: "bookmark")
            }
            // Список закладок
            Button {
                showBookmarks = true
            } label: {
                Image(systemName: "list.bullet")
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
            Text("\(Int(scrubValue))/\(pageCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
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
        } else if let progress = model.ocrProgress {
            ocrProgressView(progress)
        } else if let document = model.document {
            ZStack(alignment: .topLeading) {
                PDFKitView(document: document,
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
                           onPageChange: { page in currentPage = page })

                if let index = pendingIndex {
                    playHereBubble(for: index)
                        .position(x: tapPoint.x, y: max(tapPoint.y - 44, 28))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Меню голоса

    @ViewBuilder
    private var voiceMenu: some View {
        let voices = model.speech.availableRussianVoices
        Menu {
            if voices.isEmpty {
                Text("Русские голоса не найдены")
            } else {
                ForEach(voices, id: \.identifier) { v in
                    Button {
                        model.speech.voice = v
                        settings.voiceIdentifier = v.identifier
                    } label: {
                        Label(voiceTitle(v),
                              systemImage: model.speech.voice?.identifier == v.identifier ? "checkmark" : "")
                    }
                }
            }
        } label: {
            Image(systemName: "person.wave.2")
        }
        .disabled(voices.isEmpty)
    }

    private func voiceTitle(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium:  return v.name + " · Premium"
        case .enhanced: return v.name + " · Enhanced"
        default:        return v.name
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

    private func ocrProgressView(_ progress: Double) -> some View {
        VStack(spacing: 16) {
            ProgressView(value: progress).frame(maxWidth: 220)
            Text("Распознаём текст… \(Int(progress * 100))%")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Это скан — извлекаем текст для озвучки.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            HStack(spacing: 12) {
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
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                Text("Скорость \(ReaderView.speedLabel(speech.speed))")
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }
}
