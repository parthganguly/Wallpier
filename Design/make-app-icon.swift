// Renders Wallpier's AppIcon set. Design-time only; not part of the app target.
// usage: swift Design/make-app-icon.swift Wallpier/Assets.xcassets/AppIcon.appiconset
//
// "The Framed Horizon": an obsidian frame around a warm archival mat, around a small woodblock-style print: a
// stepped slate-indigo mountain under a Hanko-vermilion sun. Original vector art drawn here; no text, no
// third-party imagery. Each size is drawn from vectors at its own pixel size, and the smallest sizes drop
// the far ridge, the frame light and the mat shadow, and thicken the mat so the print stays legible.
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
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.34))
        c.addPath(tilePath); c.setFillColor(color(0x1D1C1A)); c.fillPath()
        c.restoreGState()
    }
    c.saveGState(); c.addPath(tilePath); c.clip()
    // The obsidian frame, with a light catch along its top edge.
    gradient(c, [color(0x2C2B28), color(0x1D1C1A)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    if !small {
        c.addPath(tilePath); c.setStrokeColor(color(0xFFFFFF, 0.14)); c.setLineWidth(5); c.strokePath()
    }

    // The mat: archival cream.
    let matInset: CGFloat = small ? 40 : 56
    let mat = tile.insetBy(dx: matInset, dy: matInset)
    let matPath = CGPath(roundedRect: mat, cornerWidth: 92, cornerHeight: 92, transform: nil)
    c.addPath(matPath); c.setFillColor(color(0xF4F0E6)); c.fillPath()

    // The print: desktop-shaped (16:10), slightly above centre like a picture hung at eye level.
    let apertureInset: CGFloat = small ? 52 : 56
    let width = mat.width - apertureInset * 2, height = width * 10 / 16
    let print = CGRect(x: mat.minX + apertureInset, y: 512 - height / 2 + 16, width: width, height: height)
    let printPath = CGPath(roundedRect: print, cornerWidth: 10, cornerHeight: 10, transform: nil)
    c.saveGState(); c.addPath(printPath); c.clip()
    gradient(c, [color(0xE9DFCB), color(0xF3ECDD)], from: CGPoint(x: 0, y: print.minY), to: CGPoint(x: 0, y: print.maxY))

    // Hanko vermilion sun.
    let radius = height * 0.14
    c.setFillColor(color(0xC24B2C))
    c.fillEllipse(in: CGRect(x: print.minX + width * 0.72 - radius, y: print.minY + height * 0.68 - radius, width: radius * 2, height: radius * 2))

    // Stepped woodblock mountains, filled from the baseline up: (x, height) corners as fractions of the print.
    func steps(_ corners: [(CGFloat, CGFloat)], fill: CGColor) {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: print.minX, y: print.minY))
        for (x, y) in corners { p.addLine(to: CGPoint(x: print.minX + width * x, y: print.minY + height * y)) }
        p.addLine(to: CGPoint(x: print.maxX, y: print.minY))
        p.closeSubpath()
        c.addPath(p); c.setFillColor(fill); c.fillPath()
    }
    if !small {
        steps([(0, 0.34), (0.1, 0.34), (0.1, 0.48), (0.26, 0.48), (0.26, 0.56), (0.44, 0.56), (0.44, 0.44), (0.7, 0.44),
               (0.7, 0.52), (0.88, 0.52), (0.88, 0.4), (1, 0.4)], fill: color(0x7A8CA0))
    }
    steps([(0, 0.2), (0.16, 0.2), (0.16, 0.36), (0.3, 0.36), (0.3, 0.54), (0.42, 0.54), (0.42, 0.7), (0.54, 0.7),
           (0.54, 0.5), (0.68, 0.5), (0.68, 0.32), (0.84, 0.32), (0.84, 0.18), (1, 0.18)], fill: color(0x2F3E4E))
    c.restoreGState()

    // The print sits into the mat: a hairline outline, plus a soft inner shadow on its upper edge at large sizes.
    if !small {
        c.saveGState(); c.addPath(printPath); c.clip()
        c.setShadow(offset: CGSize(width: 0, height: -5), blur: 12, color: color(0x000000, 0.3))
        c.addRect(print.insetBy(dx: -40, dy: -40)); c.addPath(printPath)
        c.setFillColor(color(0x000000)); c.fillPath(using: .evenOdd)
        c.restoreGState()
    }
    c.addPath(printPath); c.setStrokeColor(color(0x1D1C1A, small ? 0.55 : 0.3)); c.setLineWidth(small ? 14 : 3); c.strokePath()
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
