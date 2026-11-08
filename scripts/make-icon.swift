// 生成 Weft 的 App 图标：经纬交织的线（散乱的窗口被织成一块布），正中一扇发光的窗口（你正在用的那个）。
// 用法：swift scripts/make-icon.swift <输出目录>   → 生成 AppIcon.iconset 和 1024 预览 png
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try? FileManager.default.createDirectory(atPath: out + "/AppIcon.iconset", withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func render(_ px: Int) -> CGImage {
    let s = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // 底：macOS 图标网格（824 主体 + 100 边距），深靛蓝 → 紫
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(squircle); ctx.setFillColor(color(0x1a1035)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: cs, colors: [color(0x120c2c), color(0x2b1460), color(0x3d1a7a)] as CFArray, locations: [0, 0.6, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 100), end: CGPoint(x: 824, y: 924), options: [])
    // 右上角一点光
    let glow = CGGradient(colorsSpace: cs, colors: [color(0x8b5cf6, 0.45), color(0x8b5cf6, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 760, y: 820), startRadius: 0, endCenter: CGPoint(x: 760, y: 820), endRadius: 520, options: [])

    // 经线（竖）和纬线（横），一上一下交织
    let pos: [CGFloat] = [292, 512, 732]
    let band: CGFloat = 92
    let span: (CGFloat, CGFloat) = (150, 874)
    let warp = CGGradient(colorsSpace: cs, colors: [color(0x8f7ad6), color(0x5b45a8)] as CFArray, locations: [0, 1])!
    let weft = CGGradient(colorsSpace: cs, colors: [color(0xf472b6), color(0xa78bfa), color(0x38bdf8)] as CFArray, locations: [0, 0.5, 1])!

    func vertical(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
        let r = CGRect(x: x - band / 2, y: y0, width: band, height: y1 - y0)
        let path = CGPath(roundedRect: r, cornerWidth: band / 2, cornerHeight: band / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: color(0x000000, 0.5))
        ctx.addPath(path); ctx.setFillColor(color(0x5b45a8)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(warp, start: CGPoint(x: x, y: y1), end: CGPoint(x: x, y: y0), options: [])
        ctx.setFillColor(color(0xffffff, 0.16)); ctx.fill(CGRect(x: x - band * 0.32, y: y0, width: band * 0.14, height: y1 - y0))
        ctx.restoreGState()
    }
    func horizontal(_ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat, shadow: Bool) {
        let r = CGRect(x: x0, y: y - band / 2, width: x1 - x0, height: band)
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x000000, 0.45)) }
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: band / 2, cornerHeight: band / 2, transform: nil))
        ctx.setFillColor(color(0x000000)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: band / 2, cornerHeight: band / 2, transform: nil)); ctx.clip()
        ctx.drawLinearGradient(weft, start: CGPoint(x: span.0, y: y), end: CGPoint(x: span.1, y: y), options: [])
        // 线的高光
        ctx.setFillColor(color(0xffffff, 0.18)); ctx.fill(CGRect(x: x0, y: y + band * 0.18, width: x1 - x0, height: band * 0.14))
        ctx.restoreGState()
    }

    for y in pos { horizontal(y, span.0, span.1, shadow: true) }
    for (i, x) in pos.enumerated() {
        vertical(x, span.0, span.1)
        // 经线压在纬线上的地方：(i + j) 为奇数时纬线在上，重新画回纬线那一段
        for (j, y) in pos.enumerated() where (i + j) % 2 == 1 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: x - band / 2 - 14, y: y - band / 2 - 20, width: band + 28, height: band + 40))
            horizontal(y, x - band / 2 - 40, x + band / 2 + 40, shadow: true)
            ctx.resetClip()
            ctx.clip(to: CGRect(x: x - band / 2 - 14, y: y - band / 2 - 20, width: band + 28, height: band + 40))
            ctx.clip(to: CGRect(x: span.0, y: y - band / 2, width: span.1 - span.0, height: band))
            horizontal(y, span.0, span.1, shadow: false)
            ctx.restoreGState()
        }
    }

    // 正中：一扇发光的窗口
    let win = CGRect(x: 512 - 128, y: 512 - 104, width: 256, height: 208)
    let wp = CGPath(roundedRect: win, cornerWidth: 34, cornerHeight: 34, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 70, color: color(0xc4b5fd, 0.95))
    ctx.addPath(wp); ctx.setFillColor(color(0xffffff)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(wp); ctx.clip()
    let wg = CGGradient(colorsSpace: cs, colors: [color(0xffffff), color(0xede9fe)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(wg, start: CGPoint(x: 512, y: win.maxY), end: CGPoint(x: 512, y: win.minY), options: [])
    // 标题栏和三个小圆点
    ctx.setFillColor(color(0xddd6fe)); ctx.fill(CGRect(x: win.minX, y: win.maxY - 46, width: win.width, height: 46))
    for (k, c) in [0xf472b6, 0xa78bfa, 0x38bdf8].enumerated() {
        ctx.setFillColor(color(UInt32(c)))
        ctx.fillEllipse(in: CGRect(x: win.minX + 24 + CGFloat(k) * 30, y: win.maxY - 33, width: 20, height: 20))
    }
    // 内容：两行「字」
    ctx.setFillColor(color(0x7c3aed, 0.28))
    ctx.fill(CGRect(x: win.minX + 28, y: win.minY + 92, width: 150, height: 16))
    ctx.fill(CGRect(x: win.minX + 28, y: win.minY + 58, width: 196, height: 16))
    ctx.fill(CGRect(x: win.minX + 28, y: win.minY + 24, width: 110, height: 16))
    ctx.restoreGState()

    // 顶部一圈细边，让图标在深色 Dock 上也有轮廓
    ctx.addPath(squircle); ctx.setStrokeColor(color(0xffffff, 0.10)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()
    return ctx.makeImage()!
}

func save(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    save(render(px), "\(out)/AppIcon.iconset/icon_\(name).png")
}
save(render(1024), "\(out)/Weft-icon-1024.png")
print("✓ \(out)/AppIcon.iconset")
