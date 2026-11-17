import CoreFoundation
import Foundation

/// USB contacts are never clamped or guessed. Validate before the legacy pixel
/// converter can bridge a Boolean, divide by zero, or trap converting to Int.
/// Keep the existing BLE coordinate contract unchanged.
enum USBRequestCoordinates {
    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    static func hold(_ body: [String: Any]) throws -> Double {
        guard let raw = body["hold"] else { return 0.08 }
        guard let value = number(raw), (0...60).contains(value) else {
            throw DeviceError("USB hold must be a finite number in 0...60 seconds")
        }
        return value
    }

    static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String,
        screenSize: @autoclosure () -> CGSize?, screenName: @autoclosure () -> String
    ) throws -> (Double, Double) {
        guard let x = number(body[xKey]), let y = number(body[yKey]) else {
            throw DeviceError("USB coordinates must be finite numbers, not booleans")
        }
        if let fraction = body["fraction"] {
            guard let value = fraction as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw DeviceError("USB fraction must be a boolean")
            }
        }
        for key in ["width", "height", "maxEdge"] where body[key] != nil {
            guard let value = number(body[key]), value > 0,
                  key != "maxEdge" || (value >= 1 && value < Double(Int.max)) else {
                throw DeviceError("Invalid USB coordinate dimension: \(key)")
            }
        }
        if body["fraction"] as? Bool == true { return try bounded(x, y) }
        guard let size = screenSize(), size.width.isFinite, size.height.isFinite,
              size.width >= 1, size.height >= 1,
              size.width < Double(Int.max), size.height < Double(Int.max) else {
            throw DeviceError("USB coordinates require valid screen dimensions")
        }
        // Even a valid maxEdge can round an extreme aspect ratio to zero.
        if let edge = number(body["maxEdge"]) {
            let image = RequestCoordinates.imageSize(size, maxWidth: nil, maxEdge: Int(edge))
            guard image.0 > 0, image.1 > 0 else {
                throw DeviceError("USB screenshot dimensions round to zero")
            }
        }
        let point = try RequestCoordinates.point(body, xKey, yKey, screenSize: size, screenName: screenName())
        return try bounded(point.0, point.1)
    }

    private static func bounded(_ x: Double, _ y: Double) throws -> (Double, Double) {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw DeviceError("USB coordinates must lie within the screen; no clamping")
        }
        return (x, y)
    }
}
