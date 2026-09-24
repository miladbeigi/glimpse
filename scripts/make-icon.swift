// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.18, green: 0.47, blue: 1.0, alpha: 1),
                        NSColor(srgbRed: 0.52, green: 0.28, blue: 0.95, alpha: 1)])!.draw(in: shape, angle: -60)

    // Viewfinder corners
    let f = rect.insetBy(dx: rect.width * 0.2, dy: rect.width * 0.2)
    let len = f.width * 0.26
    let corners = NSBezierPath()
    corners.lineWidth = s * 0.045
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    for (p, dx, dy) in [(NSPoint(x: f.minX, y: f.maxY), 1.0, -1.0), (NSPoint(x: f.maxX, y: f.maxY), -1.0, -1.0),
                        (NSPoint(x: f.minX, y: f.minY), 1.0, 1.0), (NSPoint(x: f.maxX, y: f.minY), -1.0, 1.0)] {
        corners.move(to: NSPoint(x: p.x, y: p.y + dy * len))
        corners.line(to: p)
        corners.line(to: NSPoint(x: p.x + dx * len, y: p.y))
    }
    NSColor.white.setStroke()
    corners.stroke()

    // Lens
    let d = f.width * 0.34
    let lens = NSBezierPath(ovalIn: NSRect(x: f.midX - d / 2, y: f.midY - d / 2, width: d, height: d))
    NSColor.white.setFill()
    lens.fill()
    let d2 = d * 0.45
    NSColor(srgbRed: 0.35, green: 0.37, blue: 0.98, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: f.midX - d2 / 2, y: f.midY - d2 / 2, width: d2, height: d2)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(iconset.path)
