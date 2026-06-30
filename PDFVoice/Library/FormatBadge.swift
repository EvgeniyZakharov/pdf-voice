import SwiftUI

/// Компактная пометка формата книги (PDF/EPUB/FB2/TXT/DOCX) для списка/сетки.
/// В сетке кладётся оверлеем в угол обложки, в списке — чипом рядом с названием.
struct FormatBadge: View {
    let format: BookFormat

    var body: some View {
        Text(format.badge)
            .font(.system(size: 9, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.accent.opacity(0.9), in: Capsule())
            .accessibilityLabel("Формат \(format.badge)")
    }
}
