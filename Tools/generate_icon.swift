import AppKit
let size = NSSize(width: 1024, height: 1024)
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(calibratedRed: 0.02, green: 0.40, blue: 0.96, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
NSColor.white.setStroke()
let ring = NSBezierPath(ovalIn: NSRect(x: 220, y: 220, width: 584, height: 584))
ring.lineWidth = 30; ring.stroke()
let lens = NSBezierPath()
for i in 0..<6 {
    let a = Double(i) * .pi / 3
    let b = a + .pi / 2.5
    lens.move(to: NSPoint(x: 512 + cos(a) * 288, y: 512 + sin(a) * 288))
    lens.line(to: NSPoint(x: 512 + cos(b) * 116, y: 512 + sin(b) * 116))
}
lens.lineWidth = 24; lens.lineCapStyle = .round; lens.stroke()
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: 476, y: 476, width: 72, height: 72)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

