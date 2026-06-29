import SwiftUI

/// Лист «Содержание» для reflow-книг (TXT/FB2/EPUB/DOCX).
/// Показывает главы; текущая отмечена галочкой ✓.
/// Тап по главе выполняет seek без принудительного запуска воспроизведения.
struct ChapterListView: View {
    @ObservedObject var model: ReaderViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(model.chapterTitles.enumerated()), id: \.offset) { i, title in
                Button {
                    model.seekToChapter(i)
                    dismiss()
                } label: {
                    HStack {
                        Text(title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if i == model.currentChapterIndex {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    // Явная тап-цель ≥ 44pt по вертикали (accessibility)
                    .frame(minHeight: 44)
                }
            }
            .navigationTitle("Содержание")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
