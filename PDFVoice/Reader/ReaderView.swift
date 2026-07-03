import AVFoundation
import SwiftUI
import UIKit

/// Тонкий резолвер сессии: тело читалки переехало в `ReaderScreen`. Сама сессия
/// (`ReaderViewModel`) принадлежит `PlaybackCoordinator` и переживает уход с экрана —
/// поэтому здесь `@ObservedObject`, а не `@StateObject` (см. specs/R2).
struct ReaderView: View {
    let item: LibraryItem
    @EnvironmentObject private var coordinator: PlaybackCoordinator

    var body: some View {
        if let model = coordinator.active, model.itemID == item.id {
            ReaderScreen(model: model)
        } else {
            // Книга ещё не открыта в координаторе — стартуем и ждём один кадр.
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { coordinator.open(item) }
        }
    }
}

private struct ReaderScreen: View {
    @EnvironmentObject private var settings: SettingsStore
    @ObservedObject var model: ReaderViewModel

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
    /// Измеренная высота плавающей панели плеера — reflow-текст получает такой
    /// нижний inset прокрутки, чтобы конец книги читался над стеклом.
    @State private var panelHeight: CGFloat = 0
    /// Глобальный прямоугольник области чтения (между навбаром и панелью плеера).
    /// PDF/текст растянуты на весь экран (контент течёт под стеклянные бар и
    /// панель), а их тап-жест координатно работает в ГЛОБАЛЬНЫХ координатах —
    /// совпадающих с этим прямоугольником. Из него берём: верхний инсет (навбар),
    /// нижнюю границу (верх панели), позиции пузырька и кнопки возврата.
    @State private var readingFrame: CGRect = .zero
    private var contentSize: CGSize { readingFrame.size }
    /// Пользователь сейчас тащит reflow-слайдер — гасит обратную связь от onScroll.
    @State private var isReflowScrubbing = false
    /// Последняя доля, пришедшая ИЗ onScroll (эхо собственного скролла вида).
    /// Отличает её от изменения слайдера пользователем — в т.ч. через
    /// accessibility-регулировку, где onEditingChanged не вызывается.
    @State private var lastReportedFraction = 0.0

    /// Скраббер и pageBar работают по числу готовых страниц.
    private var pageCount: Int { model.loadedPageCount }

    /// Аудио готово к воспроизведению — есть хотя бы одно предложение.
    /// То же условие, по которому активна кнопка Play. Пока false — показываем
    /// экран подготовки, а НЕ читаемую страницу с мёртвой кнопкой.
    private var audioReady: Bool { !model.speech.sentences.isEmpty }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Плеер — плавающая стеклянная панель поверх нижней кромки;
            // safeAreaInset резервирует место, страница не прячется под ней.
            .safeAreaInset(edge: .bottom, spacing: 8) {
                if audioReady {
                    playerPanel
                }
            }
            .onPreferenceChange(PanelHeightKey.self) { panelHeight = $0 }
        // Фон читалки = фон СТРАНИЦЫ (не хрома): панель плеера и верхние кнопки
        // висят прямо над «бумагой», без отдельной полосы фона за ними.
        .background(pageBackdrop.ignoresSafeArea())
        // Верхний бар прозрачный: кнопки тулбара (стекло на iOS 26) висят
        // прямо над фоном, без полосы-подложки.
        .toolbarBackground(.hidden, for: .navigationBar)
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
            ChapterListView(model: model) { chapter in
                // Тап по главе = переход ПОЗИЦИИ ЧТЕНИЯ (как закладка): играет → озвучка
                // продолжается с главы; на паузе → курсор переставлен без принудительного play.
                model.seekToChapter(chapter)
                reflowCommandToken += 1
                reflowCommand = .scrollToChapter(chapter, token: reflowCommandToken)
            }
        }
        // Сессия (attach/applySettings/load) поднята в PlaybackCoordinator.open — здесь
        // НЕ грузим и НЕ завершаем её: при уходе в библиотеку аудио продолжает играть (R2).
        .onAppear { settings.probeSilero() }
        .onChange(of: settings.selectedVoice)      { _ in model.applySettings(settings) }
        // Озвучка перешла на другое предложение — пузырёк «Читать отсюда»
        // больше не актуален, прячем (иначе висел поверх текста).
        .onChange(of: model.currentSentence?.id) { _ in
            if pendingIndex != nil {
                withAnimation(.easeOut(duration: 0.12)) { pendingIndex = nil }
            }
        }
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // Фон чтения — только для reflow (на PDF тема не влияет). Смена на лету:
            // ReflowReaderView.updateUIView перекрашивает фон/текст без переоткрытия книги.
            if model.isReflowable {
                Menu {
                    Picker("Фон чтения", selection: $settings.readingTheme) {
                        ForEach(ReadingTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                }
                .accessibilityLabel("Фон чтения")
            }

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
                // Команду шлём на любое изменение, КРОМЕ эха от onScroll
                // (скролл вида/озвучки сам двигает фракцию — её не отражаем
                // обратно). Раньше гейтом был isReflowScrubbing, но он не
                // покрывал accessibility-регулировку слайдера (VoiceOver):
                // значение менялось без onEditingChanged, и вид не скроллился.
                if isReflowScrubbing || abs(value - lastReportedFraction) > 0.0005 {
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

    /// Цвет «бумаги» текущей книги: reflow — из темы чтения, PDF — крем.
    private var pageBackdrop: Color {
        model.isReflowable ? Color(settings.readingTheme.pageBackgroundUI)
                           : Theme.pageBackground
    }

    // MARK: - Плавающая панель плеера

    /// Навигация (ползунок страниц/прокрутки) + транспорт одной стеклянной картой.
    private var playerPanel: some View {
        VStack(spacing: 0) {
            if model.isReflowable {
                reflowBar
            } else if pageCount > 1 {
                pageBar
            }
            PlayerControls(model: model)
        }
        .padding(.top, 6)
        .glass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            GeometryReader { geo in
                Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
            }
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, Theme.floatingBottomPadding)
        // Панель висит над «бумагой» — стекло и акценты под тему страницы,
        // как у пузырька и кнопки возврата.
        .environment(\.colorScheme,
                     model.isReflowable && settings.readingTheme == .dark ? .dark : .light)
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
                             onScroll: { f, ch, vis, _ in
                                 // Пока юзер тащит слайдер — он источник истины, не перебиваем.
                                 if !isReflowScrubbing {
                                     lastReportedFraction = f
                                     reflowScrollFraction = f
                                 }
                                 reflowTopChapter = ch
                                 // Кнопка возврата — ВСЕГДА, когда подсветка не видна
                                 // (раньше пряталась при isFollowing, хотя текст не виден).
                                 withAnimation { showReturnButton = !vis }
                             },
                             command: reflowCommand,
                             theme: settings.readingTheme,
                             bottomClearance: panelHeight + 12,
                             readingMinY: readingFrame.minY,
                             readingMaxY: readingFrame.maxY,
                             bubbleCenter: bubbleCenter,
                             onConfirmPlay: { playFromBubble() },
                             returnButtonCenter: returnButtonCenter,
                             onReturnTap: { returnToReading() })
                // Фон reflow задаёт сама тема (ReadingTheme.pageBackgroundUI) — кремового
                // multiply-оверлея здесь нет (он тонировал бы светлую/тёмную темы). PDF
                // свой оверлей сохраняет (см. pdfContent).
                // Текст течёт под стеклянный верхний бар И под панель плеера. Тап-жест
                // работает в глобальных координатах и игнорирует зоны бара/панели
                // (readingMinY…readingMaxY), поэтому их кнопки получают тап.
                .ignoresSafeArea(.container, edges: [.top, .bottom])

            if let index = pendingIndex {
                bubbleOverlay(for: index)
            }
        }
        .background(contentSizeReader)
        .overlay(alignment: .bottomTrailing) {
            returnButton
        }
        // Плавающие элементы (стекло) — под тему СТРАНИЦЫ, не хрома: при тёмном
        // фоне чтения и светлом хроме кнопки должны быть тёмным стеклом.
        .environment(\.colorScheme, settings.readingTheme == .dark ? .dark : .light)
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
                       onFollowChanged: { vis, _ in
                           // То же правило, что в reflow: показываем, когда подсветка не видна.
                           withAnimation { showReturnButton = !vis }
                       },
                       returnToReadingToken: pdfReturnToken,
                       readingMinY: readingFrame.minY,
                       readingMaxY: readingFrame.maxY,
                       bubbleCenter: bubbleCenter,
                       onConfirmPlay: { playFromBubble() },
                       returnButtonCenter: returnButtonCenter,
                       onReturnTap: { returnToReading() })
                // Тёплая «бумага»: multiply тонирует белые страницы в крем,
                // чёрный текст остаётся читаемым. compositingGroup ограничивает
                // смешивание самим PDF.
                .compositingGroup()
                .overlay(
                    Theme.pageBackground
                        .blendMode(.multiply)
                        .allowsHitTesting(false)
                )
                // Бумага PDF течёт под верхний бар и панель плеера; тап-жест в
                // глобальных координатах игнорирует их зоны (readingMinY…MaxY).
                .ignoresSafeArea(.container, edges: [.top, .bottom])

            if let index = pendingIndex {
                bubbleOverlay(for: index)
            }

            if let progress = model.ocrProgress {
                ocrProgressBanner(progress)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .background(contentSizeReader)
        .overlay(alignment: .bottomTrailing) {
            returnButton
        }
        // Бумага PDF всегда кремовая → плавающее стекло поверх неё всегда светлое,
        // независимо от темы хрома.
        .environment(\.colorScheme, .light)
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
                    .glass(in: Circle(), interactive: true)
                    .foregroundStyle(Theme.accent)
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

    /// Позиция центра пузырька «Читать отсюда» в ГЛОБАЛЬНЫХ координатах (совпадают
    /// с координатами тапа из PDF/текста), зажата в границы области чтения. Одна
    /// точка истины: и для отрисовки пузырька, и для зоны, которую жест
    /// PDF/текста опознаёт как подтверждение.
    private var bubbleCenter: CGPoint? {
        guard pendingIndex != nil, readingFrame != .zero else { return nil }
        return CGPoint(
            x: min(max(tapPoint.x, readingFrame.minX + 30), readingFrame.maxX - 30),
            y: min(max(tapPoint.y - 44, readingFrame.minY + 28), readingFrame.maxY - 30))
    }

    /// Центр кнопки «Вернуться к чтению» (bottom-trailing области чтения, паддинги
    /// 16/12, кнопка 44) в ГЛОБАЛЬНЫХ координатах. Её тап тоже опознаёт жест
    /// PDF/текста — иначе он проваливался в контент и кнопка «не исчезала».
    private var returnButtonCenter: CGPoint? {
        guard showReturnButton, readingFrame != .zero else { return nil }
        return CGPoint(x: readingFrame.maxX - 16 - 22, y: readingFrame.maxY - 12 - 22)
    }

    /// Пузырёк «Читать отсюда» в полноэкранном оверлее (координаты глобальные,
    /// совпадают с `bubbleCenter`). Тап по нему обрабатывает жест PDF/текста
    /// (`onConfirmPlay`), кнопка — визуал + VoiceOver.
    private func bubbleOverlay(for index: Int) -> some View {
        playHereBubble(for: index)
            .position(bubbleCenter ?? .zero)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .transition(.scale.combined(with: .opacity))
    }

    /// Фоновый ридер ГЛОБАЛЬНОГО прямоугольника области чтения (между навбаром и
    /// панелью). Не влияет на хит-тест содержимого.
    private var contentSizeReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { readingFrame = geo.frame(in: .global) }
                .onChange(of: geo.frame(in: .global)) { readingFrame = $0 }
        }
    }

    /// Подтверждение «Читать отсюда»: запускает озвучку с выбранного предложения.
    /// Единый путь для тапа по SwiftUI-кнопке пузырька (VoiceOver) и для тапа,
    /// перехваченного жестом PDF/текста (`onConfirmPlay`). Guard по pendingIndex
    /// защищает от двойного срабатывания, если сработали оба.
    private func playFromBubble() {
        guard let index = pendingIndex else { return }
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
    }

    private func playHereBubble(for index: Int) -> some View {
        Button {
            playFromBubble()
        } label: {
            Image(systemName: "play.fill")
                .font(.subheadline.weight(.bold))
                .frame(width: 48, height: 48)
                .glass(in: Circle(), interactive: true)
                .foregroundStyle(Theme.accent)
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
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
        .glass(in: RoundedRectangle(cornerRadius: Theme.radiusCard))
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

}

/// Высота плавающей панели плеера (для нижнего inset'а reflow-прокрутки).
private struct PanelHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Статические хелперы (используются SettingsView и PlayerControls)

extension ReaderView {
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
        // Контролы делят ширину поровну — на узких экранах ничего не наезжает
        // (раньше чип скорости лежал в ZStack поверх транспорта и пересекался
        // с кнопкой перемотки). Иконки «в край» — шаг по предложениям, не ±сек.
        HStack(spacing: 0) {
            speedMenu
                .frame(maxWidth: .infinity)
            skipButton("backward.end.fill", label: "Предыдущее предложение") {
                speech.skipBackward()
            }
            .frame(maxWidth: .infinity)
            playButton
                .frame(maxWidth: .infinity)
            skipButton("forward.end.fill", label: "Следующее предложение") {
                speech.skipForward()
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .disabled(speech.sentences.isEmpty)
    }

    private var playButton: some View {
        Button { model.togglePlayPause() } label: {
            Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 62, height: 62)
                .glass(in: Circle(), tint: Theme.accent, interactive: true)
                .shadow(color: Theme.accent.opacity(0.18), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(speech.isSpeaking ? "Пауза" : "Играть")
    }

    /// Мягкая круглая кнопка перемотки: полупрозрачная заливка акцентом + рамка.
    private func skipButton(_ icon: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // Внутри стеклянной панели — мягкая заливка, не стекло-на-стекле.
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 48, height: 48)
                .background(Theme.accent.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
            Text(ReaderView.speedLabel(speech.speed))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.accent)
                .frame(minWidth: 30)
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(Theme.accent.opacity(0.08), in: Capsule())
        }
        .accessibilityLabel("Скорость \(ReaderView.speedLabel(speech.speed))")
    }
}
