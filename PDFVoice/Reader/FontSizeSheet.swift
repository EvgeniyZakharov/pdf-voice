import SwiftUI

/// Компактный лист регулировки размера шрифта reflow-текста (кнопка «Aa» в
/// правом верхнем углу читалки). Меняет `SettingsStore.readingFontSize` — текст
/// перевёрстывается на лету. PDF этот контрол не показывает.
struct FontSizeSheet: View {
    @Binding var fontSize: Double
    @Environment(\.dismiss) private var dismiss

    private var range: ClosedRange<Double> { SettingsStore.fontSizeRange }

    var body: some View {
        VStack(spacing: 20) {
            // Живой образец текущего размера.
            Text("Пример текста")
                .font(.system(size: fontSize))
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding(.horizontal)

            HStack(spacing: 16) {
                stepButton("textformat.size.smaller", label: "Мельче") {
                    fontSize = max(range.lowerBound, (fontSize - 1).rounded())
                }
                Text("\(Int(fontSize)) pt")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 64)
                stepButton("textformat.size.larger", label: "Крупнее") {
                    fontSize = min(range.upperBound, (fontSize + 1).rounded())
                }
            }

            Slider(value: $fontSize, in: range, step: 1)
                .padding(.horizontal)
        }
        .padding(24)
        .presentationDetents([.height(240)])
        .presentationDragIndicator(.visible)
    }

    private func stepButton(_ icon: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 52, height: 44)
                .foregroundStyle(Theme.accent)
                .background(Theme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
