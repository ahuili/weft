import AppKit
import CoreImage
import ScreenCaptureKit
import WeftCore

/// 演示模式：录介绍视频、开会共享屏幕时用。打开后
/// - 每个 App 窗口上盖一张它自己的模糊截图：颜色和大致样子都在，内容看不清
/// - Weft 自己的面板里，窗口标题换成 App 名字，缩略图打上模糊
/// Weft 自己的界面照常清楚。`weft ctl demo on|off`，或启动时带 WEFT_DEMO=1
enum DemoMode {
    @MainActor static var on = ProcessInfo.processInfo.environment["WEFT_DEMO"] == "1"

    /// 缩略图打模糊（演示模式下才动）
    static func blur(_ img: CGImage, radius: Double? = nil) -> CGImage {
        let ci = CIImage(cgImage: img).clampedToExtent()
        let r = radius ?? max(8, Double(img.width) / 28)
        guard let out = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: ci, kCIInputRadiusKey: r])?.outputImage?
            .cropped(to: CGRect(x: 0, y: 0, width: img.width, height: img.height)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return img }
        return cg
    }
}

extension WindowInfo {
    /// 界面上显示的标题：演示模式下只给 App 名字
    @MainActor var shownTitle: String { DemoMode.on || title.isEmpty ? appName : title }
}

/// 演示模式的遮罩：每个窗口上盖一张「它自己缩到 1/8 再模糊」的截图。颜色、明暗、大致布局都在，字一个也认不出来
/// （14 号字缩下来不到 2 像素，再一模糊就没了）。截图还没到的那一下先用深色毛玻璃顶着。
/// 遮罩永远不接鼠标；只动它自己的面板和 Weft 带标题栏的窗口（场景工作台、设置），舞台的幕布、占位这些一概不碰。
/// 忘了关的话 10 分钟后自己关
@MainActor
final class DemoVeil {
    private struct Cover { let panel: NSPanel; let image: NSImageView }
    private var covers: [UInt32: Cover] = [:]
    private var timer: Timer?
    private var shotTimer: Timer?
    private var autoOff: Timer?
    private var shooting = false
    private var shootAgain = false
    /// 刚被 Weft 挪过的窗口：遮罩先撑到「原位置 ∪ 目的地」，这一小会儿里不按实际位置缩回去
    private var pinned: [UInt32: Date] = [:]
    /// 提到遮罩上面的 Weft 窗口，原来的层级（关掉时还原）
    private var raised: [ObjectIdentifier: (window: NSWindow, level: NSWindow.Level)] = [:]
    static let shrink: CGFloat = 8
    static let coverLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)

    func set(_ on: Bool) {
        DemoMode.on = on
        timer?.invalidate(); timer = nil
        shotTimer?.invalidate(); shotTimer = nil
        autoOff?.invalidate(); autoOff = nil
        if on {
            update(); shoot()
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            }
            shotTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.shoot() }
            }
            autoOff = Timer.scheduledTimer(withTimeInterval: 600, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.set(false) }
            }
        } else {
            for c in covers.values { c.panel.orderOut(nil) }
            covers.removeAll()
            pinned.removeAll()
            for r in raised.values where r.window.level == Self.raisedLevel { r.window.level = r.level }
            raised.removeAll()
        }
    }

    static let raisedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 2)

    private func update() {
        let me = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let screens = NSScreen.screens
        guard let primaryH = screens.first?.frame.height else { return }
        var seen = Set<UInt32>()
        var fresh = false
        // CG 是从前到后：倒着摆，前面窗口的那层盖在后面窗口那层上面
        for w in list.reversed() {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            let ns = NSRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            // 藏到屏幕外、只露一条边的后台窗口不用盖
            let shown = screens.map { $0.frame.intersection(ns) }.filter { !$0.isNull }.map { $0.width * $0.height }.max() ?? 0
            guard shown > 120 * 80 else { continue }
            seen.insert(id)
            let c: Cover
            if let have = covers[id] { c = have } else { c = make(); covers[id] = c; fresh = true }
            if let t = pinned[id], Date() < t { c.panel.orderFrontRegardless(); continue }
            pinned[id] = nil
            if c.panel.frame != ns { c.panel.setFrame(ns, display: true) }
            c.panel.orderFrontRegardless()
        }
        for (id, c) in covers where !seen.contains(id) { c.panel.orderOut(nil); covers[id] = nil; pinned[id] = nil }
        if fresh { shoot() }
        // Weft 自己带标题栏的窗口（场景工作台、设置）要在遮罩上面。只动这种：
        // 舞台的幕布是整块屏那么大的面板，以前它也被提了上来，盖住了所有窗口、鼠标全被它接走
        for w in NSApp.windows where w.isVisible && w.styleMask.contains(.titled) && w.level.rawValue < Self.raisedLevel.rawValue {
            raised[ObjectIdentifier(w)] = (w, w.level)
            w.level = Self.raisedLevel
        }
    }

    /// Weft 要挪窗口了（AX 挪窗口是同步的，挪完才返回）：遮罩先盖住「原来的位置 ∪ 要去的位置」，窗口在哪一帧都不会露出来
    func willMove(_ id: UInt32, to cg: CGRect) {
        guard DemoMode.on, let primaryH = NSScreen.screens.first?.frame.height else { return }
        let to = NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
        guard NSScreen.screens.contains(where: { $0.frame.intersection(to).width > 40 && $0.frame.intersection(to).height > 40 }) else { return }   // 挪去屏幕外藏起来的，不用管
        let c: Cover
        if let have = covers[id] { c = have } else { c = make(); covers[id] = c; shoot() }
        let from = c.panel.isVisible ? c.panel.frame : to
        c.panel.setFrame(from.union(to), display: true)
        c.panel.orderFrontRegardless()
        CATransaction.flush()
        pinned[id] = Date().addingTimeInterval(0.2)
    }

    /// 给盖着的窗口截一张小图、打模糊
    private func shoot() {
        guard Permissions.screenCapture, !covers.isEmpty else { return }
        guard !shooting else { shootAgain = true; return }
        shooting = true
        let want = Set(covers.keys)
        Task { @MainActor in
            defer {
                self.shooting = false
                if self.shootAgain, DemoMode.on { self.shootAgain = false; self.shoot() }
            }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for w in content.windows where want.contains(w.windowID) && w.frame.width > 60 {
                let f = SCContentFilter(desktopIndependentWindow: w)
                let cfg = SCStreamConfiguration()
                cfg.width = max(8, Int(w.frame.width / Self.shrink)); cfg.height = max(8, Int(w.frame.height / Self.shrink))
                cfg.showsCursor = false
                guard let img = try? await SCScreenshotManager.captureImage(contentFilter: f, configuration: cfg), DemoMode.on else { continue }
                let blurred = DemoMode.blur(img, radius: 3)
                self.covers[w.windowID]?.image.image = NSImage(cgImage: blurred, size: NSSize(width: blurred.width, height: blurred.height))
            }
        }
    }

    private func make() -> Cover {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 比普通窗口高一层，比 Weft 自己的界面低：Weft 的界面在遮罩上面，照常清楚
        p.level = Self.coverLevel
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false

        // 截图还没到时的底：深色毛玻璃（只闪一下）
        let fx = NSVisualEffectView()
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        fx.layer?.masksToBounds = true
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.6).cgColor
        tint.autoresizingMask = [.width, .height]
        fx.addSubview(tint)

        let shot = NSImageView()
        shot.imageScaling = .scaleAxesIndependently
        shot.autoresizingMask = [.width, .height]
        fx.addSubview(shot)
        p.contentView = fx
        return Cover(panel: p, image: shot)
    }
}
