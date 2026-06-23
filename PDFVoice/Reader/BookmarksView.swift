import SwiftUI

struct BookmarksView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.bookmarks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "bookmark.slash")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("Закладок нет")
                            .font(.headline)
                        Text("Нажмите  в читалке, чтобы добавить.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.bookmarks) { bm in
                            Button {
                                model.navigate(to: bm)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bm.preview)
                                        .font(.body)
                                        .lineLimit(2)
                                        .foregroundStyle(.primary)
                                    HStack {
                                        Text("Стр. \(bm.pageIndex + 1)")
                                        Spacer()
                                        Text(bm.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { model.bookmarks[$0] }.forEach(model.removeBookmark)
                        }
                    }
                }
            }
            .navigationTitle("Закладки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
