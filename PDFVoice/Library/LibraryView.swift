import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var coordinator: PlaybackCoordinator
    @State private var path: [LibraryItem] = []
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var showSettings = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "pv.onboarded")

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else if settings.libraryLayout == .grid {
                    gridView
                } else {
                    listView
                }
            }
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
            // Холодный старт: didSet appearance не срабатывает на значении из init.
            .onAppear { AppearanceController.apply(settings.appearance) }
            .navigationDestination(for: LibraryItem.self) { item in
                ReaderView(item: item)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !store.items.isEmpty {
                        Button {
                            withAnimation { settings.libraryLayout = settings.libraryLayout == .list ? .grid : .list }
                        } label: {
                            Image(systemName: settings.libraryLayout.icon)
                        }
                    }
                    Button { showingImporter = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .sheet(isPresented: $showOnboarding) {
                OnboardingView(isPresented: $showOnboarding)
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
    }

    // MARK: - Табличный вид

    private var listView: some View {
        List {
            ForEach(store.items) { item in
                NavigationLink(value: item) {
                    HStack(spacing: 12) {
                        BookCoverView(fileURL: item.fileURL, fileName: item.fileName,
                                      fixedSize: CGSize(width: 40, height: 56))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.body).lineLimit(2)
                            HStack(spacing: 6) {
                                FormatBadge(format: item.format)
                                if let opened = item.lastOpened {
                                    Text("Открыто \(opened.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .contextMenu { deleteButton(item) }
            }
            .onDelete(perform: deleteItems)
        }
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
                    ForEach(store.items) { item in
                        NavigationLink(value: item) {
                            VStack(spacing: 6) {
                                BookCoverView(fileURL: item.fileURL, fileName: item.fileName)
                                    .overlay(alignment: .bottomLeading) {
                                        FormatBadge(format: item.format)
                                            .padding(6)
                                    }
                                Text(item.title)
                                    .font(.caption)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.primary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu { deleteButton(item) }
                    }
                }
                .padding(padding)
            }
        }
    }

    private func deleteButton(_ item: LibraryItem) -> some View {
        Button(role: .destructive) {
            coordinator.stopIfActive(item.id)
            store.delete(item)
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try store.importBook(from: url)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteItems(_ offsets: IndexSet) {
        offsets.map { store.items[$0] }.forEach { item in
            coordinator.stopIfActive(item.id)
            store.delete(item)
        }
    }
}
