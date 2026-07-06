import SwiftUI

/// Лист «Содержание» для reflow-книг (TXT/FB2/EPUB/DOCX).
/// Показывает главы; текущая отмечена галочкой ✓.
/// Тап по главе переносит ПОЗИЦИЮ ЧТЕНИЯ на начало главы (как закладка): играет →
/// озвучка продолжается с главы; на паузе — курсор переставлен без принудительного
/// старта. Вид всегда скроллит к выбранной главе.
struct ChapterListView: View {
    @ObservedObject var model: ReaderViewModel
    /// Выбор главы → переносит позицию чтения (см. `ReaderViewModel.seekToChapter`)
    /// и скроллит вид к началу главы.
    var onSelect: (Int) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(Array(model.chapterTitles.enumerated()), id: \.offset) { i, title in
                Button {
                    // dismiss() СНАЧАЛА, onSelect — отложенно на следующий тик: если во
                    // время активного воспроизведения переставить позицию озвучки (мутация
                    // SpeechEngine у ЖИВОЙ сессии) в ТОЙ ЖЕ транзакции, что и закрытие листа,
                    // SwiftUI иногда схлопывает оба изменения так, что presenting-view
                    // (ReaderScreen) не подхватывает новую подсветку/позицию — на экране
                    // остаётся старая глава, хотя вид уже проскроллен. Разносим по тикам —
                    // как и для bubble-подтверждения «Читать отсюда» (там сработавший путь
                    // не завязан на закрытие листа и этой гонки не имеет).
                    dismiss()
                    DispatchQueue.main.async { onSelect(i) }
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
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Содержание")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
