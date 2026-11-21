import AppKit

@main
struct MakeIcon {
    private struct Variant {
        let points: Int
        let scale: Int

        var pixels: Int { points * scale }
        var name: String { "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png" }
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: MakeIcon PATH.iconset\n".utf8))
            exit(64)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var bitmaps: [Int: Data] = [:]
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let variant = Variant(points: points, scale: scale)
                let data: Data
                if let existing = bitmaps[variant.pixels] {
                    data = existing
                } else {
                    data = try render(pixels: variant.pixels)
                    bitmaps[variant.pixels] = data
                }
                try data.write(to: folder.appendingPathComponent(variant.name))
            }
        }
    }

    private static func render(pixels: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        let tile = NSBezierPath(roundedRect: NSRect(x: 86, y: 101, width: 852, height: 838),
                                xRadius: 207, yRadius: 207)
        context.saveGState()
        if pixels >= 64 {
            context.setShadow(offset: CGSize(width: 0, height: -17), blur: 31,
                              color: NSColor.black.withAlphaComponent(0.32).cgColor)
        }
        color(0x0D1117).setFill()
        tile.fill()
        context.restoreGState()
        NSGradient(starting: color(0x212830), ending: color(0x0D1117))?.draw(in: tile, angle: -68)
        color(0x3D444D).setStroke()
        tile.lineWidth = 6
        tile.stroke()

        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 349, y: 292))
        stem.line(to: NSPoint(x: 349, y: 718))
        stem.lineWidth = 45
        stem.lineCapStyle = .round
        color(0x4493F8).setStroke()
        stem.stroke()

        let fork = NSBezierPath()
        fork.move(to: NSPoint(x: 350, y: 397))
        fork.curve(to: NSPoint(x: 660, y: 624), controlPoint1: NSPoint(x: 535, y: 402),
                   controlPoint2: NSPoint(x: 658, y: 468))
        fork.lineWidth = 45
        fork.lineCapStyle = .round
        color(0x4493F8).setStroke()
        fork.stroke()

        node(x: 349, y: 292, radius: 59, shade: 0x4493F8, hole: false)
        node(x: 349, y: 718, radius: 70, shade: 0x79C0FF, hole: true)
        node(x: 660, y: 624, radius: 70, shade: 0x79C0FF, hole: true)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    private static func node(x: CGFloat, y: CGFloat, radius: CGFloat, shade: UInt32, hole: Bool) {
        let bounds = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
        color(shade).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        if hole {
            color(0x151B23).setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: radius * 0.55, dy: radius * 0.55)).fill()
        }
    }

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
