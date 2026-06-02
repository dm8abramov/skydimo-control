import AppKit
import Foundation

let iconsetPath = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
let icnsPath = CommandLine.arguments.dropFirst(2).first
let iconsetURL = URL(fileURLWithPath: iconsetPath)
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    let url = iconsetURL.appendingPathComponent(name)
    try drawIcon(pixels: pixels).write(to: url)
}

if let icnsPath {
    try writeICNS(iconsetURL: iconsetURL, outputURL: URL(fileURLWithPath: icnsPath))
}

private func drawIcon(pixels: Int) throws -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let size = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    bounds.fill()

    let inset = size * 0.07
    let background = NSBezierPath(
        roundedRect: bounds.insetBy(dx: inset, dy: inset),
        xRadius: size * 0.19,
        yRadius: size * 0.19
    )
    NSGradient(colors: [
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1.0),
        NSColor(calibratedRed: 0.02, green: 0.025, blue: 0.035, alpha: 1.0),
    ])!.draw(in: background, angle: 315)

    let glowRect = NSRect(x: size * 0.15, y: size * 0.12, width: size * 0.70, height: size * 0.70)
    let glow = NSBezierPath(ovalIn: glowRect)
    NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.10, alpha: 0.58),
        NSColor(calibratedRed: 1.0, green: 0.28, blue: 0.02, alpha: 0.04),
    ])!.draw(in: glow, relativeCenterPosition: NSPoint(x: 0.0, y: -0.18))

    let monitorRect = NSRect(x: size * 0.22, y: size * 0.31, width: size * 0.56, height: size * 0.38)
    let monitor = NSBezierPath(
        roundedRect: monitorRect,
        xRadius: size * 0.045,
        yRadius: size * 0.045
    )
    NSColor(calibratedWhite: 0.92, alpha: 0.96).setStroke()
    monitor.lineWidth = max(2, size * 0.026)
    monitor.stroke()

    let screen = NSBezierPath(
        roundedRect: monitorRect.insetBy(dx: size * 0.045, dy: size * 0.045),
        xRadius: size * 0.025,
        yRadius: size * 0.025
    )
    NSColor(calibratedRed: 0.02, green: 0.03, blue: 0.04, alpha: 0.76).setFill()
    screen.fill()

    let stand = NSBezierPath()
    stand.move(to: NSPoint(x: size * 0.50, y: size * 0.31))
    stand.line(to: NSPoint(x: size * 0.50, y: size * 0.21))
    stand.move(to: NSPoint(x: size * 0.38, y: size * 0.20))
    stand.line(to: NSPoint(x: size * 0.62, y: size * 0.20))
    stand.lineCapStyle = .round
    stand.lineWidth = max(2, size * 0.026)
    NSColor(calibratedWhite: 0.90, alpha: 0.92).setStroke()
    stand.stroke()

    let ledPath = NSBezierPath()
    ledPath.move(to: NSPoint(x: size * 0.22, y: size * 0.28))
    ledPath.curve(
        to: NSPoint(x: size * 0.78, y: size * 0.28),
        controlPoint1: NSPoint(x: size * 0.34, y: size * 0.12),
        controlPoint2: NSPoint(x: size * 0.66, y: size * 0.12)
    )
    ledPath.lineCapStyle = .round
    ledPath.lineWidth = max(3, size * 0.055)
    NSColor(calibratedRed: 1.0, green: 0.36, blue: 0.04, alpha: 0.96).setStroke()
    ledPath.stroke()

    let hotPath = NSBezierPath()
    hotPath.move(to: NSPoint(x: size * 0.28, y: size * 0.27))
    hotPath.curve(
        to: NSPoint(x: size * 0.72, y: size * 0.27),
        controlPoint1: NSPoint(x: size * 0.39, y: size * 0.18),
        controlPoint2: NSPoint(x: size * 0.61, y: size * 0.18)
    )
    hotPath.lineCapStyle = .round
    hotPath.lineWidth = max(2, size * 0.026)
    NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.24, alpha: 0.95).setStroke()
    hotPath.stroke()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "GenerateIcon", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not encode icon PNG"
        ])
    }
    return data
}

private func writeICNS(iconsetURL: URL, outputURL: URL) throws {
    let entries: [(type: String, file: String)] = [
        ("icp4", "icon_16x16.png"),
        ("icp5", "icon_16x16@2x.png"),
        ("icp6", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_128x128@2x.png"),
        ("ic09", "icon_256x256@2x.png"),
        ("ic10", "icon_512x512@2x.png"),
    ]

    var body = Data()
    for entry in entries {
        let png = try Data(contentsOf: iconsetURL.appendingPathComponent(entry.file))
        body.append(entry.type.data(using: .ascii)!)
        body.appendUInt32BE(UInt32(8 + png.count))
        body.append(png)
    }

    var icns = Data()
    icns.append("icns".data(using: .ascii)!)
    icns.appendUInt32BE(UInt32(8 + body.count))
    icns.append(body)
    try icns.write(to: outputURL)
}

private extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
