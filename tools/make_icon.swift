// Renders the app icon set: a glassy gradient squircle with the SF Symbol iPod.
// Usage: swift tools/make_icon.swift iPodDrop/Assets.xcassets/AppIcon.appiconset
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 body with ~22.5% corner radius.
    let inset = size * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = body.width * 0.225
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 1.0, green: 0.36, blue: 0.42, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.16, blue: 0.33, alpha: 1),
                        NSColor(srgbRed: 0.62, green: 0.10, blue: 0.42, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Glass highlight on the upper half.
    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSColor.white.withAlphaComponent(0.35).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: size * 0.004, dy: size * 0.004),
                           xRadius: radius, yRadius: radius)
    rim.lineWidth = max(1, size * 0.006)
    rim.stroke()

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .regular)
        .applying(.init(paletteColors: [.white, NSColor(srgbRed: 0.62, green: 0.10, blue: 0.30, alpha: 0.55)]))
    if let symbol = NSImage(systemSymbolName: "ipod", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let s = symbol.size
        symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(base)x\(base)\(scale == 2 ? "@2x" : "").png"
        try! render(base * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                       options: [.prettyPrinted, .sortedKeys])
try! json.write(to: out.appendingPathComponent("Contents.json"))
print("wrote \(images.count) icons")
