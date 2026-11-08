import AppKit

/// 菜单栏图标：和 App 图标同一个意象——两经两纬交织，中间一扇窗。舞台模式时窗口变实心。
enum WeftGlyph {
    static func menuBar(stage: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let band: CGFloat = 2.0
            // 经纬线（两横两竖，留出交叉处的缝隙表现「一上一下」）
            for x in [3.3, 14.7] as [CGFloat] {
                NSBezierPath(roundedRect: NSRect(x: x - band / 2, y: 1, width: band, height: 16), xRadius: 1.1, yRadius: 1.1).fill()
            }
            for (i, y) in ([3.3, 14.7] as [CGFloat]).enumerated() {
                // 纬线在第 i 根经线上方的地方，把经线挖开一点
                for (j, x) in ([3.3, 14.7] as [CGFloat]).enumerated() where (i + j) % 2 == 1 {
                    NSGraphicsContext.current?.compositingOperation = .clear
                    NSRect(x: x - band / 2 - 0.2, y: y - band / 2 - 1, width: band + 0.4, height: band + 2).fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                }
                let segs: [(CGFloat, CGFloat)] = [(1, 17)]
                for (a, b) in segs {
                    let r = NSRect(x: a, y: y - band / 2, width: b - a, height: band)
                    NSBezierPath(roundedRect: r, xRadius: 1.1, yRadius: 1.1).fill()
                }
                // 经线在上方的地方，把纬线挖开
                for (j, x) in ([3.3, 14.7] as [CGFloat]).enumerated() where (i + j) % 2 == 0 {
                    NSGraphicsContext.current?.compositingOperation = .clear
                    NSRect(x: x - band / 2 - 1, y: y - band / 2 - 0.2, width: 1, height: band + 0.4).fill()
                    NSRect(x: x + band / 2, y: y - band / 2 - 0.2, width: 1, height: band + 0.4).fill()
                    NSGraphicsContext.current?.compositingOperation = .sourceOver
                    NSRect(x: x - band / 2, y: y - band / 2, width: band, height: band).fill()
                }
            }
            // 中间的窗口
            let win = NSRect(x: 5.6, y: 5.6, width: 6.8, height: 6.8)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: win.insetBy(dx: -0.8, dy: -0.8), xRadius: 2, yRadius: 2).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            let p = NSBezierPath(roundedRect: win, xRadius: 1.3, yRadius: 1.3)
            if stage { p.fill() } else { p.lineWidth = 1.3; p.stroke() }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Weft"
        return img
    }
}
