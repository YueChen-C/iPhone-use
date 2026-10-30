// Editable icon artwork. Run `swift scripts/generate-icon.swift` from the repository root.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let files = FileManager.default
let temporary = files.temporaryDirectory.appendingPathComponent("iphone-use-icon-\(UUID().uuidString)")
let iconset = temporary.appendingPathComponent("AppIcon.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temporary) }

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 255) / 255,
        green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(
        roundedRect: CGRect(x: x, y: y, width: width, height: height),
        cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ context: CGContext, in path: CGPath, colors: [CGColor], from: CGPoint, to: CGPoint) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let blend = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(
        blend, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()
}

func glow(_ context: CGContext, in path: CGPath, center: CGPoint, radius: CGFloat, tint: CGColor) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let blend = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [tint, tint.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(
        blend, startCenter: center, startRadius: 0,
        endCenter: center, endRadius: radius, options: [])
    context.restoreGState()
}

func stroke(_ context: CGContext, _ path: CGPath, tint: CGColor, width: CGFloat) {
    context.setStrokeColor(tint)
    context.setLineWidth(width)
    context.addPath(path)
    context.strokePath()
}

func translated(_ path: CGPath, x: CGFloat, y: CGFloat) -> CGPath {
    var transform = CGAffineTransform(translationX: x, y: y)
    return path.copy(using: &transform)!
}

func polygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    for index in points.indices {
        let point = points[index]
        let previous = points[(index + points.count - 1) % points.count]
        let next = points[(index + 1) % points.count]
        let incoming = hypot(previous.x - point.x, previous.y - point.y)
        let outgoing = hypot(next.x - point.x, next.y - point.y)
        let distance = min(radius, min(incoming, outgoing) / 3)
        let start = CGPoint(
            x: point.x + (previous.x - point.x) * distance / incoming,
            y: point.y + (previous.y - point.y) * distance / incoming)
        let end = CGPoint(
            x: point.x + (next.x - point.x) * distance / outgoing,
            y: point.y + (next.y - point.y) * distance / outgoing)
        if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
        path.addQuadCurve(to: end, control: point)
    }
    path.closeSubpath()
    return path
}

// Intersect inset edges to give the cursor an actual bevel around its concave silhouette.
func inset(_ points: [CGPoint], by distance: CGFloat) -> [CGPoint] {
    let area = points.indices.reduce(CGFloat.zero) { total, index in
        let a = points[index]
        let b = points[(index + 1) % points.count]
        return total + a.x * b.y - b.x * a.y
    }
    let direction: CGFloat = area > 0 ? 1 : -1
    return points.indices.map { index in
        let a = points[(index + points.count - 1) % points.count]
        let b = points[index]
        let c = points[(index + 1) % points.count]
        let first = CGPoint(x: b.x - a.x, y: b.y - a.y)
        let second = CGPoint(x: c.x - b.x, y: c.y - b.y)
        let firstLength = hypot(first.x, first.y)
        let secondLength = hypot(second.x, second.y)
        let p = CGPoint(
            x: b.x - first.y / firstLength * distance * direction,
            y: b.y + first.x / firstLength * distance * direction)
        let q = CGPoint(
            x: b.x - second.y / secondLength * distance * direction,
            y: b.y + second.x / secondLength * distance * direction)
        let cross = first.x * second.y - first.y * second.x
        let t = ((q.x - p.x) * second.y - (q.y - p.y) * second.x) / cross
        return CGPoint(x: p.x + t * first.x, y: p.y + t * first.y)
    }
}

func artwork() -> CGImage {
    let context = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setAllowsAntialiasing(true)

    // A glazed ceramic tile with a recessed face, a lit upper rim and a deep lower edge.
    let tileBody = rounded(100, 112, 824, 824, 184)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24, color: color(0x020C1E, alpha: 0.5))
    context.setFillColor(color(0x07172F))
    context.addPath(tileBody)
    context.fillPath()
    context.restoreGState()
    gradient(
        context, in: tileBody, colors: [color(0x325879), color(0x040F23)],
        from: CGPoint(x: 200, y: 160), to: CGPoint(x: 800, y: 936))
    let tile = rounded(100, 88, 824, 824, 184)
    gradient(
        context, in: tile, colors: [color(0x77AAC4), color(0x254764), color(0x0B1E38)],
        from: CGPoint(x: 160, y: 88), to: CGPoint(x: 860, y: 912))
    let face = rounded(110, 98, 804, 804, 176)
    gradient(
        context, in: face, colors: [color(0x355B7E), color(0x102942), color(0x10253C)],
        from: CGPoint(x: 200, y: 98), to: CGPoint(x: 800, y: 902))
    glow(context, in: face, center: CGPoint(x: 260, y: 160), radius: 650, tint: color(0x81CEE3, alpha: 0.22))
    glow(context, in: face, center: CGPoint(x: 800, y: 850), radius: 540, tint: color(0x36D3BB, alpha: 0.12))
    stroke(context, rounded(102, 90, 820, 820, 182), tint: color(0xE2F7FF, alpha: 0.22), width: 2)

    // The handset's complete silhouette is centered at (512, 512), including its 20 px depth.
    let phoneBack = rounded(328, 204, 368, 636, 80)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 14, height: -24), blur: 28, color: color(0x000814, alpha: 0.65))
    context.setFillColor(color(0x587183))
    context.addPath(phoneBack)
    context.fillPath()
    context.restoreGState()
    gradient(
        context, in: phoneBack,
        colors: [color(0x9AB4C5), color(0xE6F1F7), color(0x617F94), color(0x223C53)],
        from: CGPoint(x: 328, y: 600), to: CGPoint(x: 696, y: 690))
    stroke(context, rounded(330, 206, 364, 632, 78), tint: color(0xB1D2DB, alpha: 0.55), width: 2)
    let phone = rounded(328, 184, 368, 636, 80)
    gradient(
        context, in: phone,
        colors: [color(0xFFFFFF), color(0xDCEBF1), color(0x8BA5BA), color(0x47677E)],
        from: CGPoint(x: 358, y: 184), to: CGPoint(x: 660, y: 820))
    stroke(context, rounded(330, 186, 364, 632, 78), tint: color(0xF1FFFF, alpha: 0.85), width: 2)
    gradient(
        context, in: rounded(336, 192, 352, 620, 73),
        colors: [color(0x8DA9B8), color(0xF2FAFF), color(0xDCEAF0)],
        from: CGPoint(x: 345, y: 195), to: CGPoint(x: 670, y: 810))
    let screenRim = rounded(346, 202, 332, 600, 62)
    gradient(
        context, in: screenRim, colors: [color(0x031725), color(0x0D293A), color(0x89ADBE)],
        from: CGPoint(x: 350, y: 202), to: CGPoint(x: 665, y: 802))
    let screen = rounded(350, 206, 324, 592, 58)
    gradient(
        context, in: screen, colors: [color(0x126B77), color(0x0D3E59), color(0x092339)],
        from: CGPoint(x: 350, y: 206), to: CGPoint(x: 674, y: 798))
    glow(
        context, in: screen, center: CGPoint(x: 390, y: 258), radius: 380,
        tint: color(0x62E8CC, alpha: 0.65))
    glow(
        context, in: screen, center: CGPoint(x: 658, y: 710), radius: 350,
        tint: color(0x428AD8, alpha: 0.32))

    context.saveGState()
    context.addPath(screen)
    context.clip()
    let ribbon = CGMutablePath()
    ribbon.move(to: CGPoint(x: 320, y: 658))
    ribbon.addCurve(to: CGPoint(x: 720, y: 346), control1: CGPoint(x: 360, y: 412), control2: CGPoint(x: 492, y: 300))
    ribbon.addLine(to: CGPoint(x: 720, y: 490))
    ribbon.addCurve(to: CGPoint(x: 320, y: 810), control1: CGPoint(x: 512, y: 456), control2: CGPoint(x: 514, y: 708))
    ribbon.closeSubpath()
    gradient(
        context, in: ribbon, colors: [color(0x86FFE4, alpha: 0.48), color(0x21A79C, alpha: 0.03)],
        from: CGPoint(x: 560, y: 350), to: CGPoint(x: 430, y: 770))
    let reflection = polygon(
        [CGPoint(x: 340, y: 196), CGPoint(x: 570, y: 196), CGPoint(x: 340, y: 632)], radius: 0)
    gradient(
        context, in: reflection, colors: [color(0xF0FFFF, alpha: 0.22), color(0xF0FFFF, alpha: 0)],
        from: CGPoint(x: 380, y: 212), to: CGPoint(x: 520, y: 630))
    context.restoreGState()
    stroke(context, rounded(351, 207, 322, 590, 57), tint: color(0xE4FFFF, alpha: 0.18), width: 1.5)
    let island = rounded(460, 228, 104, 28, 14)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -2), blur: 2, color: color(0xA0F4DD, alpha: 0.25))
    context.setFillColor(color(0x051C2B))
    context.addPath(island)
    context.fillPath()
    context.restoreGState()
    glow(context, in: island, center: CGPoint(x: 550, y: 236), radius: 10, tint: color(0x2D5167, alpha: 0.9))
    context.setFillColor(color(0xE8FCFF, alpha: 0.7))
    context.addPath(rounded(470, 769, 84, 6, 3))
    context.fillPath()

    // A compact porcelain pointer: rounded corners, machined bevel and mint-colored side walls.
    let points = [
        CGPoint(x: 558, y: 492), CGPoint(x: 558, y: 686), CGPoint(x: 604, y: 641),
        CGPoint(x: 647, y: 730), CGPoint(x: 692, y: 708), CGPoint(x: 649, y: 620),
        CGPoint(x: 714, y: 613),
    ]
    let cursor = polygon(points, radius: 5)
    let cursorBack = translated(cursor, x: 8, y: 12)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 12, height: -20), blur: 18, color: color(0x00101F, alpha: 0.7))
    context.setFillColor(color(0x1B6B6D))
    context.addPath(cursorBack)
    context.fillPath()
    context.restoreGState()
    for layer in stride(from: 12, through: 1, by: -1) {
        let path = translated(cursor, x: CGFloat(layer) * 2 / 3, y: CGFloat(layer))
        gradient(
            context, in: path, colors: [color(0xB3F4DF), color(0x39A993), color(0x0E6266)],
            from: CGPoint(x: 560, y: 500), to: CGPoint(x: 708, y: 742))
    }
    gradient(
        context, in: cursor, colors: [color(0xFFFFFF), color(0xE2FFF6), color(0x81B6AA)],
        from: CGPoint(x: 558, y: 500), to: CGPoint(x: 690, y: 730))
    gradient(
        context, in: polygon(inset(points, by: 7), radius: 3),
        colors: [color(0xFFFFFF), color(0xE5FFF7), color(0xBDE7DB)],
        from: CGPoint(x: 558, y: 500), to: CGPoint(x: 692, y: 710))
    stroke(context, cursor, tint: color(0xF0FFF9, alpha: 0.65), width: 1.5)
    return context.makeImage()!
}

// Downsample the same artwork so shadows and bevels keep their proportions at every size.
let master = artwork()
func image(size: Int) -> CGImage {
    if size == master.width { return master }
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(master, in: CGRect(x: 0, y: 0, width: size, height: size))
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try writePNG(
            image(size: points * scale), to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

let preview = root.appendingPathComponent("Resources/AppIcon.png")
try writePNG(image(size: 1024), to: preview)
let resourceDirectory = root.appendingPathComponent("Sources/iPhoneUse/Resources")
try files.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
let icon = resourceDirectory.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", icon.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
print("Generated \(preview.path) and \(icon.path)")
