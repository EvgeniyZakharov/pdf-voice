import SwiftUI

/// Лист «Содержание» для reflow-книг (TXT/FB2/EPUB/DOCX).
/// Показывает главы; текущая отмечена галочкой ✓.
/// Тап по главе скроллит ВИД к главе (browse), НЕ запуская озвучку — как навигация
/// по миниатюрам/скрабберу в PDF. Позиция чтения/аудио не меняется.
struct ChapterListView: View {
    @ObservedObject var model: ReaderViewModel
    /// Выбор главы → навигация ВИДА (скролл), без запуска озвучки.
    var onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(model.chapterTitles.enumerated()), id: \.offset) { i, title in
                Button {
                    onSelect(i)
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
