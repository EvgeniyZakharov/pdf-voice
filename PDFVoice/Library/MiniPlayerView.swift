import SwiftUI
import UIKit

/// Компактный плеер внизу библиотеки: показывается, пока жива сессия чтения
/// (`PlaybackCoordinator.active`). Тап по строке возвращает в читалку, кнопки —
/// play/pause и закрыть. Аудио продолжает играть при уходе в библиотеку (R2).
struct MiniPlayerView: View {
    @ObservedObject var model: ReaderViewModel
    @ObservedObject private var speech: SpeechEngine
    let onOpen: () -> Void
    let onClose: () -> Void

    init(model: ReaderViewModel, onOpen: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = ObservedObject(wrappedValue: model)
        _speech = ObservedObject(wrappedValue: model.speech)
        self.onOpen = onOpen
        self.onClose = onClose
    }

    private var item: LibraryItem { model.libraryItem }

    var body: some View {
        // Плавающая карточка поверх списка: скругления + тень + тонкая рамка
        // (не бар от края до края) — читается как отдельный слой.
        HStack(spacing: 12) {
                // Строка (обложка + заголовок) → возврат в читалку.
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    BookCoverView(fileURL: item.fileURL, fileName: item.fileName,
                                  fixedSize: CGSize(width: 36, height: 50))
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Открыть «\(item.title)»")

            Button { model.togglePlayPause() } label: {
                Image(systemName: speech.isSpeaking ? "pause.fill" : "play.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    // Кликабельна вся площадь 44×44, а не только пиксели глифа.
                    .contentShape(Rectangle())
            }
            .disabled(speech.sentences.isEmpty)
            .accessibilityLabel(speech.isSpeaking ? "Пауза" : "Играть")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Закрыть плеер")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .glass(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.bottom, Theme.floatingBottomPadding)
    }
}
