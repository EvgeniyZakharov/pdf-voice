import Foundation

/// Таймер сна: паузирует озвучку через N минут.
@MainActor
final class SleepTimer: ObservableObject {
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var isActive: Bool = false

    static let options = [5, 10, 15, 30, 45, 60]   // минуты

    var onExpire: (() -> Void)?
    private var task: Task<Void, Never>?

    func start(minutes: Int) {
        task?.cancel()
        remainingSeconds = minutes * 60
        isActive = true
        task = Task {
            while !Task.isCancelled, remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                remainingSeconds -= 1
            }
            guard !Task.isCancelled else { return }
            isActive = false
            onExpire?()
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
