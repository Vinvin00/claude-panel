// Draws the app icon: a dark rounded square with an orange sparkle and a green light.
// Usage: icon <output.iconset>   (build.sh turns the folder into AppIcon.icns)
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let k = CGFloat(px) / 1024
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * k, y: y * k) }

    // square with the margin macOS icons use
    let body = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k),
                            xRadius: 185 * k, yRadius: 185 * k)
    NSColor(white: 0.075, alpha: 1).setFill()
    body.fill()
    NSColor(white: 1, alpha: 0.12).setStroke()
    body.lineWidth = 6 * k
    body.stroke()

    // four-point sparkle: curved sides pulled toward the middle
    let c = pt(480, 560), r = 270 * k, pull = 38 * k
    let star = NSBezierPath()
    star.move(to: NSPoint(x: c.x, y: c.y + r))
    star.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + pull, y: c.y + pull),
               controlPoint2: NSPoint(x: c.x + pull, y: c.y + pull))
    star.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + pull, y: c.y - pull),
               controlPoint2: NSPoint(x: c.x + pull, y: c.y - pull))
    star.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - pull, y: c.y - pull),
               controlPoint2: NSPoint(x: c.x - pull, y: c.y - pull))
    star.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - pull, y: c.y + pull),
               controlPoint2: NSPoint(x: c.x - pull, y: c.y + pull))
    star.close()
    NSColor(red: 1, green: 0.62, blue: 0.25, alpha: 1).setFill()
    star.fill()

    // the green "working" light
    NSColor(red: 0.25, green: 0.75, blue: 0.48, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: (700 - 46) * k, y: (330 - 46) * k, width: 92 * k, height: 92 * k)).fill()

    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512),
                   ("512x512@2x", 1024)] {
    try draw(px).write(to: URL(fileURLWithPath: "\(dir)/icon_\(name).png"))
}
