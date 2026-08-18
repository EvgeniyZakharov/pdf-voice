import Foundation

/// Таймер сна: паузирует озвучку через N минут.
@MainActor
final class SleepTimer: ObservableObject {
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isActive: Bool = false

    static let options = [5, 10, 15, 30, 45, 60]   // минуты

    var onExpire: (() -> Void)?
    private var task: Task<Void, Never>?

    /// Отсчёт по дедлайну (`Date`), не сложением `Task.sleep(1s)` — иначе суммарная
    /// погрешность 60 однопроцентных задержек (планировщик, фон) на 60-минутном
    /// таймере набегает в заметные секунды/минуты рассинхрона с реальным временем.
    func start(minutes: Int) {
        task?.cancel()
        let deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
        remainingSeconds = minutes * 60
        isActive = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { break }
                self.remainingSeconds = Int(remaining.rounded(.up))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.remainingSeconds = 0
            self.isActive = false
            self.onExpire?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
        remainingSeconds = 0
    }

    var remainingFormatted: String {
        let m = remainingSeconds / 60
        let s = remainingSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
