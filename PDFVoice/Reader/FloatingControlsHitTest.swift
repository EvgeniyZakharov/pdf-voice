import CoreGraphics

/// Действие, распознанное тапом по одной из плавающих кнопок читалки (пузырёк
/// «Читать отсюда»/«закладка», кнопка «Вернуться к чтению»). Общий словарь для
/// `PDFKitView` и `ReflowReaderView` — оба ловят тап собственным UIKit-жестом
/// (SwiftUI-кнопка поверх representable не получает его надёжно) и раньше
/// дублировали три одинаковые `hypot`-проверки.
enum FloatingControlAction {
    case confirmPlay
    case bookmark
    case returnToReading
}

enum FloatingControlsHitTest {
    /// Радиус хит-зоны кнопок пузырька (play/закладка) — совпадает с 44pt
    /// круглыми кнопками капсулы `bubbleButtons`.
    static let bubbleRadius: CGFloat = 28
    /// Радиус хит-зоны кнопки «Вернуться к чтению» (44pt круг + небольшой запас).
    static let returnRadius: CGFloat = 30

    /// Определяет действие по точке тапа в координатах ВЬЮПОРТА (совпадают с
    /// координатами центров, которые считает `ReaderView`). Порядок проверки —
    /// play, затем закладка, затем возврат — как в исходных местах.
    static func action(at point: CGPoint,
                       bubbleCenter: CGPoint?,
                       bookmarkCenter: CGPoint?,
                       returnButtonCenter: CGPoint?) -> FloatingControlAction? {
        if let c = bubbleCenter, hypot(point.x - c.x, point.y - c.y) <= bubbleRadius {
            return .confirmPlay
        }
        if let c = bookmarkCenter, hypot(point.x - c.x, point.y - c.y) <= bubbleRadius {
            return .bookmark
        }
        if let c = returnButtonCenter, hypot(point.x - c.x, point.y - c.y) <= returnRadius {
            return .returnToReading
        }
        return nil
    }
}
