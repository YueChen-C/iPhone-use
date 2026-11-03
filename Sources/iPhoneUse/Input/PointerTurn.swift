import Foundation

/// Rotation from raw HID axes to the captured screen. A proof is session-local.
enum PointerTurn: Int, CaseIterable {
    case none, clockwise, half, counterclockwise

    func screenPoint(for p: CGPoint) -> CGPoint {
        switch self {
        case .none: return p
        case .clockwise: return CGPoint(x: 1 - p.y, y: p.x)
        case .half: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .counterclockwise: return CGPoint(x: p.y, y: 1 - p.x)
        }
    }

    func rawPoint(for p: CGPoint) -> CGPoint {
        switch self {
        case .none: return p
        case .clockwise: return CGPoint(x: p.y, y: 1 - p.x)
        case .half: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case .counterclockwise: return CGPoint(x: 1 - p.y, y: p.x)
        }
    }

    func rawDelta(dx: Int, dy: Int) -> (Int, Int) {
        switch self {
        case .none: return (dx, dy)
        case .clockwise: return (dy, -dx)
        case .half: return (-dx, -dy)
        case .counterclockwise: return (-dy, dx)
        }
    }
}
