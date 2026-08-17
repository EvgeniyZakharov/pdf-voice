import SwiftUI
import UniformTypeIdentifiers

/// Фильтр библиотеки: встроенные срезы + пользовательские коллекции.
enum LibraryFilter: Hashable {
    case all
    case collection(UUID)
}

struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @State private var path: [LibraryItem] = []
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var showSettings = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "pv.onboarded")

    // Коллекции / фильтры
    @State private var selectedFilter: LibraryFilter = .all
    @State private var showCreateCollection = false
    @State private var newCollectionName = ""
    /// Книга, для которой открыт лист выбора коллекции.
    @State private var assigningItem: LibraryItem?

    /// Книги, прошедшие текущий фильтр.
    private var filteredItems: [LibraryItem] {
        switch selectedFilter {
        case .all:      return store.items
        case .collection(let id):
            guard store.collections.contains(where: { $0.id == id }) else { return store.items }
            return store.items.filter { $0.collectionIDs.contains(id) }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            libraryContent
            .background(Theme.background.ignoresSafeArea())
            // Мини-плеер живёт на корневом экране библиотеки; при пуше ReaderView он
            // естественно перекрыт. safeAreaInset резервирует место — список не прячется.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let active = coordinator.active {
                    MiniPlayerView(model: active,
                                   onOpen: { path.append(active.libraryItem) },
                                   onClose: { coordinator.stop() })
                }
            }
            .navigationTitle("Библиотека")
            // Всегда компактный заголовок по центру (без крупного «Библиотека»).
            .navigationBarTitleDisplayMode(.inline)
            // Холодный старт: didSet appearance не срабатывает на значении из init.
            .onAppear { AppearanceController.apply(settings.appearance) }
            // Выбранная коллекция удалена — возвращаемся к «Все», чтобы не залипнуть
            // на пустом срезе несуществующей коллекции.
            .onChange(of: store.collections) { cols in
                if case .collection(let id) = selectedFilter,
                   !cols.contains(where: { $0.id == id }) {
                    selectedFilter = .all
                }
            }
            .navigationDestination(for: LibraryItem.self) { item in
                ReaderView(item: item)
            }
            .toolbar { toolbarContent }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
            }
            .sheet(item: $assigningItem) { item in
                CollectionPickerView(itemID: item.id)
                    .environmentObject(store)
            }
            .alert("Новая коллекция", isPresented: $showCreateCollection) {
                TextField("Название", text: $newCollectionName)
                Button("Создать") {
                    let c = store.createCollection(name: newCollectionName)
                    selectedFilter = .collection(c.id)
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Введите название коллекции.")
            }
            .fileImporter(isPresented: $showingImporter,
                          allowedContentTypes: BookFormat.importContentTypes,
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .alert("Не удалось добавить файл",
                   isPresented: .constant(importError != nil)) {
                Button("OK") { importError = nil }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        if store.items.isEmpty {
            emptyState
        } else {
            // Блок фильтров — закреплённый верхний inset (safeAreaInset), а не сосед
            // по VStack: список/сетка тянутся ВВЕРХ под него, и книги при скролле
            // уходят под коллекции, а не исчезают в пустой полосе над списком.
            // Непрозрачная подложка (Theme.background) прячет уезжающие карточки.
            filteredContent
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Без непрозрачной подложки: стеклянный блок ПЛАВАЕТ над списком.
                    // Книги при скролле заходят под него (матируются сквозь стекло) и
                    // выглядывают у скруглённых углов — нет жёсткой прямой линии обреза.
                    filterBar
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 6)
                        .frame(maxWidth: .infinity)
                }
        }
    }

    @ViewBuilder
    private var filteredContent: some View {
        if filteredItems.isEmpty {
            filterEmptyState
        } else if settings.libraryLayout == .grid {
            gridView
        } else {
            listView
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
            }
            .toolbarGlassCircle()
        }
        if #available(iOS 26.0, *) {
            // iOS 26: система сама рисует Liquid Glass за кнопками тулбара — не трогаем.
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.items.isEmpty { layoutToggleButton }
                importButton
            }
        } else {
            // iOS < 26: свой общий стеклянный «капсульный» контейнер для сетки+плюса —
            // как на iOS 26, где эти кнопки объединены в одну капсулу. Иначе на старых
            // iOS иконки шапки висят голыми без фона.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    if !store.items.isEmpty { layoutToggleButton }
                    importButton
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.hairline, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            }
        }
    }

    private var layoutToggleButton: some View {
        Button {
            withAnimation { settings.libraryLayout = settings.libraryLayout == .list ? .grid : .list }
        } label: {
            Image(systemName: settings.libraryLayout.icon)
        }
    }

    private var importButton: some View {
        Button { showingImporter = true } label: {
            Image(systemName: "plus")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Пока пусто")
                .font(.headline)
            Text("Нажмите + и выберите PDF, чтобы начать слушать.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(40)
        // Та же причина, что у filterEmptyState: заглушка должна занимать экран,
        // иначе содержимое схлопывается по своей высоте.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Пусто для текущего среза (книги в библиотеке есть, но под фильтр не попали).
    ///
    /// `maxHeight: .infinity` обязателен: соседние ветки (`listView`/`gridView`) —
    /// это ScrollView, которые сами занимают весь экран. Без растяжения заглушка
    /// отдавала свою СОБСТВЕННУЮ высоту, и при переходе в пустую коллекцию
    /// схлопывался весь контент: панель фильтров съезжала к середине экрана,
    /// а мини-плеер прилипал к тексту вместо нижней кромки.
    private var filterEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Здесь пока нет книг")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Панель фильтров / коллекций

    /// Единый стеклянный блок: чипы «Все»/«PDF» + коллекции + кнопка создания.
    /// Живёт ВНУТРИ прокручиваемого контента (первой строкой списка / верхом сетки),
    /// чтобы крупный заголовок «Библиотека» снова сжимался при скролле, а блок
    /// коллекций уезжал вверх вместе с контентом.
    private var filterBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    filterChip(title: "Все", count: store.items.count, filter: .all)
                    ForEach(store.collections) { c in
                        filterChip(title: c.name, count: store.bookCount(in: c.id),
                                   filter: .collection(c.id))
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.deleteCollection(c)
                                } label: {
                                    Label("Удалить коллекцию", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.horizontal, 4)
            }
            // Справа — создание коллекции (popup с вводом названия).
            Button { newCollectionName = ""; showCreateCollection = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
            .accessibilityLabel("Создать коллекцию")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        // Внешние отступы (в т.ч. горизонтальные для выравнивания с книгами) задаёт
        // вызывающая сторона. Здесь блок заканчивается ровно по краю стекла, чтобы
        // карточки уходили под него без пустой полосы снизу.
    }

    private func filterChip(title: String, count: Int?, filter: LibraryFilter) -> some View {
        let selected = selectedFilter == filter
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { selectedFilter = filter }
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(.medium))
                if let count {
                    Text("\(count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(selected ? Theme.onAccent.opacity(0.85) : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(selected ? Theme.onAccent : Color.primary)
            .background {
                // Невыбранные — прозрачные (единый стеклянный блок читается как одно
                // целое); выбранный — заливка акцентом.
                Capsule().fill(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.clear))
            }
        }
        .buttonStyle(.plain)
    }


    // MARK: - Табличный вид

    private var listView: some View {
        List {
            ForEach(filteredItems) { item in
                HStack(spacing: 12) {
                    BookCoverView(fileURL: item.fileURL, fileName: item.fileName,
                                  fixedSize: CGSize(width: 40, height: 56))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.body).lineLimit(2)
                        HStack(spacing: 6) {
                            FormatBadge(format: item.format)
                            if item.isFinished {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.accent)
                            }
                            if let opened = item.lastOpened {
                                Text("Открыто \(opened.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    bookMenu(item)
                }
                // Строка — отдельная приподнятая карточка со скруглением, вжатая на
                // 16 pt от краёв (как блок коллекций). Плоский `listRowBackground`
                // сливался с фоном (surface ≈ background), и бокового отступа не было
                // видно; карточка + тень делают отступ явным.
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 1)
                // Тап по строке (кроме меню) открывает книгу — onTapGesture, не
                // NavigationLink, чтобы соседнее меню-многоточие не дёргало навигацию.
                .contentShape(Rectangle())
                .onTapGesture { path.append(item) }
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .onDelete(perform: deleteItems)
        }
        // Plain-стиль убирает крупный верхний инсет grouped-списка — книги
        // начинаются сразу под блоком коллекций, без лишнего провала.
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Сетка (как в iBooks)

    private var gridView: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 16
            let padding: CGFloat = 16
            let minItem: CGFloat = 110     // ~3 в портрете на обычном iPhone, 2 на маленьком
            let available = geo.size.width - padding * 2
            let cols = max(2, Int((available + spacing) / (minItem + spacing)))
            let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: cols)

            ScrollView {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                    ForEach(filteredItems) { item in
                        VStack(spacing: 6) {
                            BookCoverView(fileURL: item.fileURL, fileName: item.fileName)
                                .overlay(alignment: .bottomLeading) {
                                    FormatBadge(format: item.format)
                                        .padding(6)
                                }
                                .overlay(alignment: .topTrailing) {
                                    bookMenu(item)
                                        .padding(4)
                                }
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { path.append(item) }
                    }
                }
                .padding(padding)
            }
        }
    }

    // MARK: - Меню книги (отправить / коллекция / удалить)

    private func bookMenu(_ item: LibraryItem) -> some View {
        Menu {
            ShareLink(item: item.fileURL) {
                Label("Отправить", systemImage: "square.and.arrow.up")
            }
            Button {
                assigningItem = item
            } label: {
                Label("Добавить в коллекцию", systemImage: "folder.badge.plus")
            }
            // Язык книги задаёт и профиль разбора, и голос озвучки. Обычно
            // определяется сам, но детект иногда ошибается — правка должна быть
            // под рукой, иначе книга навсегда останется на чужом голосе.
            Menu {
                Picker("Язык книги", selection: languageBinding(for: item)) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
            } label: {
                Label("Язык книги", systemImage: "character.book.closed")
            }
            Divider()
            Button(role: .destructive) {
                coordinator.stopIfActive(item.id)
                store.delete(item)
            } label: {
                Label("Удалить", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
        }
        .accessibilityLabel("Меню книги")
    }

    /// Биндинг языка книги для пикера в меню. Смена языка меняет и профиль
    /// разбора (заголовки, раскрытие чисел), поэтому книга переизвлекается —
    /// см. `DocumentStore.changeLanguage`.
    private func languageBinding(for item: LibraryItem) -> Binding<String> {
        Binding(
            get: { item.effectiveLanguage },
            set: { newValue in
                guard newValue != item.effectiveLanguage else { return }
                coordinator.stopIfActive(item.id)
                store.changeLanguage(newValue, for: item.id)
            }
        )
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let item = try store.importBook(from: url)
                // Импорт при открытой коллекции → книга сразу попадает в неё.
                if case .collection(let cid) = selectedFilter {
                    store.setMembership(itemID: item.id, collectionID: cid, member: true)
                }
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteItems(_ offsets: IndexSet) {
        offsets.map { filteredItems[$0] }.forEach { item in
            coordinator.stopIfActive(item.id)
            store.delete(item)
        }
    }
}
