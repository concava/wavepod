import AppKit
// Renders the Wavepod mark (same path as WaveShape in Theme.swift) as the 1024 px macOS app icon.
// swiftc -O tools/render-icon.swift -o /tmp/render-icon && /tmp/render-icon icon_1024.png, then resize with sips
// into App/Resources/Assets.xcassets/AppIcon.appiconset.
let size = 1024.0
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
// macOS icon grid: 824 pt body centred in 1024, continuous corners.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(shape); ctx.setFillColor(color(0xF7F4EE)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(shape); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFBF9F4), color(0xEFEBE2)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
// The mark, same maths as WaveShape, in a 26:20 box.
let w = 600.0, h = w * 20 / 26
let rect = CGRect(x: (size - w) / 2, y: (size - h) / 2, width: w, height: h)
let path = CGMutablePath()
path.move(to: CGPoint(x: rect.minX, y: rect.midY))
for i in 0...600 {
    let t = Double(i) / 600
    let envelope = max(0, 1 - t * 1.25)
    path.addLine(to: CGPoint(x: rect.minX + rect.width * t, y: rect.midY + sin(t * .pi * 7) * envelope * rect.height * 0.28))
}
ctx.addPath(path)
ctx.setStrokeColor(color(0x0F5E63)); ctx.setLineWidth(58); ctx.setLineCap(.round); ctx.setLineJoin(.round)
ctx.strokePath()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
