import SwiftUI
import UIKit

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
                        Text("Тапните по предложению при чтении и нажмите значок закладки, чтобы отметить место.")
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
                                        Text("Страница \(bm.pageIndex + 1)")
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
                        .listRowBackground(Theme.surface)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Закладки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                    }
                }
            }
        }
    }
}
