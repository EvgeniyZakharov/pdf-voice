import SwiftUI

/// Лист выбора коллекций для книги (меню книги → «Добавить в коллекцию»).
/// Тумблер принадлежности по галочке + создание новой коллекции прямо здесь.
/// Читает актуальное состояние из `store` по `itemID` (снапшот книги не хранит),
/// поэтому галочки и счётчики не устаревают при переключении.
struct CollectionPickerView: View {
    @EnvironmentObject private var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    let itemID: UUID

    @State private var showCreate = false
    @State private var newName = ""

    private var memberIDs: Set<UUID> {
        Set(store.items.first(where: { $0.id == itemID })?.collectionIDs ?? [])
    }

    var body: some View {
        NavigationStack {
            List {
                if store.collections.isEmpty {
                    Text("Коллекций пока нет — создайте первую.")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Theme.surface)
                } else {
                    ForEach(store.collections) { c in
                        Button {
                            store.setMembership(itemID: itemID, collectionID: c.id,
                                                member: !memberIDs.contains(c.id))
                        } label: {
                            HStack {
                                Text(c.name).foregroundStyle(.primary)
                                Spacer()
                                Text("\(store.bookCount(in: c.id))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if memberIDs.contains(c.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                }

                Button { newName = ""; showCreate = true } label: {
                    Label("Новая коллекция", systemImage: "plus")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Добавить в коллекцию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
            .alert("Новая коллекция", isPresented: $showCreate) {
                TextField("Название", text: $newName)
                Button("Создать") {
                    let c = store.createCollection(name: newName)
                    store.setMembership(itemID: itemID, collectionID: c.id, member: true)
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
}
