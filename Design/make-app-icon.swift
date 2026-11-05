// Renders Wallpier's AppIcon set. Design-time only; not part of the app target.
// usage: swift Design/make-app-icon.swift Wallpier/Assets.xcassets/AppIcon.appiconset
//
// A warm gallery mat holding a 16:10 desktop-shaped aperture: a quiet dusk landscape whose
// near ridge rises in a soft "W". Each size is drawn from vectors at its own pixel size, and
// the smallest sizes drop the far ridge and thicken the mat so the window stays legible.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ c: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func render(pixels: Int) -> Data {
    let s = CGFloat(pixels) / 1024
    let small = pixels <= 32
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: s, y: s)

    // Big Sur grid: an 824pt tile centred on the 1024pt canvas, with the standard soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    if !small {
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.32))
        c.addPath(tilePath); c.setFillColor(color(0xEEEAE1)); c.fillPath()
        c.restoreGState()
    }
    c.saveGState(); c.addPath(tilePath); c.clip()
    gradient(c, [color(0xF7F4EE), color(0xE4DED2)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))

    // The aperture: desktop-shaped (16:10), slightly above centre like a picture hung at eye level.
    let inset: CGFloat = small ? 150 : 180
    let width = 1024 - inset * 2, height = width * 10 / 16
    let window = CGRect(x: inset, y: 512 - height / 2 + 14, width: width, height: height)
    let windowPath = CGPath(roundedRect: window, cornerWidth: 26, cornerHeight: 26, transform: nil)
    c.saveGState(); c.addPath(windowPath); c.clip()
    gradient(c, [color(0x29486E), color(0x5C7FA3), color(0xE9B48A)],
             from: CGPoint(x: 0, y: window.maxY), to: CGPoint(x: 0, y: window.minY + height * 0.32))

    let sun = CGRect(x: window.minX + width * 0.64, y: window.minY + height * 0.42, width: height * 0.2, height: height * 0.2)
    c.setFillColor(color(0xFFE7BC)); c.fillEllipse(in: sun)

    func ridge(_ points: [(CGFloat, CGFloat)], fill: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: window.minX, y: window.minY))
        p.addLine(to: CGPoint(x: window.minX, y: window.minY + height * points[0].1))
        for i in 1..<points.count {
            let (x0, y0) = points[i - 1], (x1, y1) = points[i]
            let a = CGPoint(x: window.minX + width * x0, y: window.minY + height * y0)
            let b = CGPoint(x: window.minX + width * x1, y: window.minY + height * y1)
            p.addCurve(to: b, control1: CGPoint(x: (a.x + b.x) / 2, y: a.y), control2: CGPoint(x: (a.x + b.x) / 2, y: b.y))
        }
        p.addLine(to: CGPoint(x: window.maxX, y: window.minY))
        p.closeSubpath()
        c.addPath(p); c.setFillColor(fill); c.fillPath()
    }
    if !small { ridge([(0, 0.50), (0.22, 0.62), (0.48, 0.47), (0.78, 0.58), (1, 0.44)], fill: color(0x6E86A0)) }
    // The near ridge: a gentle W — two valleys between three rounded rises.
    ridge([(0, 0.40), (0.25, 0.14), (0.5, 0.34), (0.75, 0.14), (1, 0.40)], fill: color(0x23384D))
    c.restoreGState()

    // The photograph sits into the mat: a hairline shadow on its upper edge, a light lip below.
    if !small {
        c.saveGState(); c.addPath(windowPath); c.clip()
        c.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.35))
        c.addRect(window.insetBy(dx: -40, dy: -40)); c.addPath(windowPath)
        c.setFillColor(color(0x000000)); c.fillPath(using: .evenOdd)
        c.restoreGState()
    }
    c.addPath(windowPath); c.setStrokeColor(color(0x1B2A3A, small ? 0.55 : 0.28)); c.setLineWidth(small ? 24 : 4); c.strokePath()
    c.restoreGState()

    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try! render(pixels: points * scale).write(to: out.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: out.appendingPathComponent("Contents.json"))
