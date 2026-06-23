import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var store: DocumentStore
    @EnvironmentObject private var settings: SettingsStore
    @State private var showingImporter = false
    @State private var importError: String?
    @State private var showSettings = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "pv.onboarded")

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Библиотека")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingImporter = true } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gear")
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
                          allowedContentTypes: [.pdf],
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

    private var list: some View {
        List {
            ForEach(store.items) { item in
                NavigationLink(value: item) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.body)
                        if let opened = item.lastOpened {
                            Text("Открыто \(opened.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDelete(perform: deleteItems)
        }
        .navigationDestination(for: LibraryItem.self) { item in
            ReaderView(item: item)
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try store.importPDF(from: url)
            } catch {
                importError = error.localizedDescription
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func deleteItems(_ offsets: IndexSet) {
        offsets.map { store.items[$0] }.forEach(store.delete)
    }
}
