import AppKit
import ScreenCaptureKit
import WeftCore

/// 藏到后台的窗口是挪到屏幕外的，可 macOS 不许窗口整个离开屏幕：每个都会在屏幕角上留 1 像素宽的一条边，
/// 有 Dock 的屏还得把标题栏留在 Dock 上面。十几个窗口的这条边叠在一起，阴影就成了角上一片灰。
///
/// 这里在那个角上盖一小块「桌面本来的样子」（截的是桌面图和桌面图标，不含任何窗口）：
/// - 只盖这些边和它们的阴影，别的窗口占着的地方挖空，不挡你的窗口
/// - 不接鼠标，点击照常穿过去
/// - 按着鼠标（可能在拖窗口）时先撤掉，松开再盖
/// - 没有录屏权限就不盖（截不到桌面）
@MainActor
final class ParkVeil {
    private let model: AppModel
    private var panels: [UInt32: NSPanel] = [:]
    /// 每块屏上次盖的范围和那块桌面图（范围没变就不重截）
    private var shots: [UInt32: (rect: CGRect, image: CGImage, at: Date)] = [:]
    private var timer: Timer?
    private var capturing = Set<UInt32>()
    /// 阴影往外扩多少
    static let margin: CGFloat = 34

    init(model: AppModel) { self.model = model }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    private func hideAll() { for p in panels.values where p.isVisible { p.orderOut(nil) } }

    func update() {
        guard !model.stash.entries.isEmpty, Permissions.screenCapture,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else { hideAll(); return }
        let parked = Set(model.stash.entries.filter { $0.viaMinimize != true }.map(\.windowID))
        let me = ProcessInfo.processInfo.processIdentifier
        let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        var strips: [CGRect] = [], others: [CGRect] = []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  let id = w[kCGWindowNumber as String] as? UInt32,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { continue }
            if parked.contains(id) { strips.append(r) } else if (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.05 { others.append(r) }
        }
        var used = Set<UInt32>()
        for d in model.profile.displays {
            // 只要藏好的那种细边（最多几像素宽 / 高）；App 自己把窗口拉回来露出一大块的不算，等它重新藏好
            let bits = strips.map { $0.intersection(d.frame) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 && min($0.width, $0.height) <= 3 }
            guard let first = bits.first else { continue }
            let area = bits.dropFirst().reduce(first) { $0.union($1) }.insetBy(dx: -Self.margin, dy: -Self.margin).intersection(d.frame).integral
            guard area.width < 400, area.height < 400 else { continue }
            used.insert(d.id)
            let holes = others.map { $0.intersection(area) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            show(d, area: area, holes: holes)
        }
        for (id, p) in panels where !used.contains(id) && p.isVisible { p.orderOut(nil) }
    }

    private func show(_ d: DisplayInfo, area: CGRect, holes: [CGRect]) {
        // 桌面图：范围变了、或者十分钟没截过（动态壁纸会变）就重截一张
        guard let shot = shots[d.id], shot.rect == area, Date().timeIntervalSince(shot.at) < 600 else {
            capture(d, area: area)
            panels[d.id]?.orderOut(nil)
            return
        }
        let p = panels[d.id] ?? makePanel()
        panels[d.id] = p
        let top = NSScreen.screens.first?.frame.height ?? 0
        p.setFrame(NSRect(x: area.minX, y: top - area.maxY, width: area.width, height: area.height), display: false)
        let v = p.contentView as! VeilView
        v.image = shot.image
        // 换成这块面板自己的坐标（左下原点）
        v.holes = holes.map { NSRect(x: $0.minX - area.minX, y: area.maxY - $0.maxY, width: $0.width, height: $0.height) }
        v.needsDisplay = true
        if !p.isVisible { p.orderFrontRegardless() }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // 比普通窗口高一级：盖得住藏起来的那些边；比 Dock、菜单栏和 Weft 自己的面板都低
        p.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        p.isReleasedWhenClosed = false
        p.contentView = VeilView()
        return p
    }

    private func capture(_ d: DisplayInfo, area: CGRect) {
        guard !capturing.contains(d.id) else { return }
        capturing.insert(d.id)
        Task { @MainActor in
            defer { self.capturing.remove(d.id) }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let disp = content.displays.first(where: { $0.displayID == d.id }) else { return }
            // 只要桌面图和桌面图标这两层（层级是负的），任何 App 的窗口都不进来
            let desk = content.windows.filter { $0.windowLayer < 0 && $0.frame.intersects(d.frame) }
            guard !desk.isEmpty else { return }
            let filter = SCContentFilter(display: disp, including: desk)
            let cfg = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            cfg.sourceRect = area.offsetBy(dx: -d.frame.minX, dy: -d.frame.minY)
            cfg.width = Int(area.width * scale)
            cfg.height = Int(area.height * scale)
            cfg.showsCursor = false
            guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) else { return }
            self.shots[d.id] = (area, img, Date())
            self.update()
        }
    }
}

private final class VeilView: NSView {
    var image: CGImage?
    var holes: [NSRect] = []
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, let image else { return }
        ctx.clear(bounds)
        ctx.draw(image, in: bounds)
        // 别的窗口占着的地方挖空
        for h in holes { ctx.clear(h) }
    }
}
