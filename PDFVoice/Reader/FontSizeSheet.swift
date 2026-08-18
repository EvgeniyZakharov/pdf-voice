import SwiftUI

/// Компактный лист регулировки размера шрифта reflow-текста (кнопка «Aa» в
/// правом верхнем углу читалки). Меняет `SettingsStore.readingFontSize` — текст
/// перевёрстывается на лету. PDF этот контрол не показывает.
///
/// Пересборка `ReflowReaderView.attributedText` на смену шрифта — недешёвая
/// операция на большой книге (полный `ensureLayout`), поэтому биндинг наружу
/// (`fontSize`) коммитится НЕ на каждый тик слайдера, а на отпускание пальца
/// (`onEditingChanged(false)`) — как в `pageBar`/`reflowBar`. Кнопки ± коммитят
/// сразу: это единичные дискретные события, а не поток кадров драга.
struct FontSizeSheet: View {
    @Binding var fontSize: Double
    /// Живое значение для превью текста внутри листа — двигается на каждый тик
    /// слайдера, независимо от коммита наружу.
    @State private var liveValue: Double
    @Environment(\.dismiss) private var dismiss

    init(fontSize: Binding<Double>) {
        self._fontSize = fontSize
        self._liveValue = State(initialValue: fontSize.wrappedValue)
    }

    private var range: ClosedRange<Double> { SettingsStore.fontSizeRange }

    var body: some View {
        VStack(spacing: 20) {
            // Живой образец текущего размера.
            Text("Пример текста")
                .font(.system(size: liveValue))
                .frame(maxWidth: .infinity, minHeight: 60)
                .padding(.horizontal)

            HStack(spacing: 16) {
                stepButton("textformat.size.smaller", label: "Мельче") {
                    liveValue = max(range.lowerBound, (liveValue - 1).rounded())
                    fontSize = liveValue
                }
                Text("\(Int(liveValue)) pt")
                    .font(.headline.monospacedDigit())
                    .frame(minWidth: 64)
                stepButton("textformat.size.larger", label: "Крупнее") {
                    liveValue = min(range.upperBound, (liveValue + 1).rounded())
                    fontSize = liveValue
                }
            }

            Slider(value: $liveValue, in: range, step: 1) { editing in
                if !editing { fontSize = liveValue }
            }
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
