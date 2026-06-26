import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool

    private let steps: [(icon: String, color: Color, title: String, body: String)] = [
        ("doc.badge.plus",   Theme.accent, "Добавьте PDF",
         "Нажмите + и выберите любой PDF-файл — книгу, статью, документ."),
        ("play.circle.fill", Theme.accent, "Слушайте вслух",
         "Нажмите ▶ — приложение читает вслух с подсветкой текущего предложения. Работает офлайн."),
        ("hand.tap.fill",    Theme.accent, "Читать отсюда",
         "Тапните по любому предложению — появится кнопка «Отсюда». Чтение начнётся с выбранного места."),
        ("slider.horizontal.3", Theme.accent, "Настройте под себя",
         "Выбирайте скорость и голос. Прогресс сохраняется автоматически.")
    ]

    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(steps.indices, id: \.self) { i in
                    stepView(steps[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: page)

            Button {
                if page < steps.count - 1 {
                    page += 1
                } else {
                    UserDefaults.standard.set(true, forKey: "pv.onboarded")
                    isPresented = false
                }
            } label: {
                Text(page < steps.count - 1 ? "Далее" : "Начать")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(steps[page].color, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .animation(.easeInOut, value: page)
        }
        .interactiveDismissDisabled()
    }

    private func stepView(_ step: (icon: String, color: Color, title: String, body: String)) -> some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(step.color.opacity(0.12))
                    .frame(width: 120, height: 120)
                Image(systemName: step.icon)
                    .font(.system(size: 52))
                    .foregroundStyle(step.color)
            }
            Text(step.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(step.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
            Spacer()
        }
    }
}
