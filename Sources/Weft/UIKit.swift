import AppKit
import SwiftUI
import WeftCore

/// 能成为 key window 但不激活本 App 的浮层（Spotlight 式）
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func make(level: NSWindow.Level = .statusBar) -> KeyPanel {
        let p = KeyPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                         backing: .buffered, defer: true)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        return p
    }
}

/// 毛玻璃背景
struct Glass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

func appIcon(_ pid: Int32) -> NSImage {
    NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)!
}

/// 一张窗口卡片：缩略图 + 图标 + 标题
struct WindowCard: View {
    let window: WindowInfo
    let thumb: NSImage?
    var selected = false
    var accent: Color = .accentColor
    var badge: String? = nil
    var subtitle: String = ""
    var width: CGFloat = 232
    var flags: [String] = []

    var height: CGFloat { width * 0.62 }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.28))
                if let thumb {
                    Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height, alignment: .top).clipped()
                } else {
                    Image(nsImage: appIcon(window.pid)).resizable().frame(width: width * 0.24, height: width * 0.24)
                        .shadow(radius: 6)
                }
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(alignment: .topLeading) {
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 22, height: 22).background(Circle().fill(accent)).padding(7)
                }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    ForEach(flags, id: \.self) { f in
                        Text(f).font(.system(size: 11)).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.ultraThinMaterial))
                    }
                }.padding(7)
            }
            .overlay(alignment: .bottomLeading) {
                if thumb != nil {
                    Image(nsImage: appIcon(window.pid)).resizable().frame(width: 26, height: 26)
                        .shadow(color: .black.opacity(0.4), radius: 3).padding(7)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? accent : Color.white.opacity(0.10), lineWidth: selected ? 3 : 1)
            )
            .shadow(color: selected ? accent.opacity(0.55) : .black.opacity(0.25), radius: selected ? 14 : 6, y: 3)

            Text(window.title.isEmpty ? window.appName : window.title)
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.primary)
            if !subtitle.isEmpty {
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: width)
        .scaleEffect(selected ? 1.04 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: selected)
    }
}

// MARK: - 轻提示

enum Toast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ text: String, seconds: Double = 2.6) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 40, height: 38)
        let p = panel ?? {
            let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient]
            panel = p
            return p
        }()
        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 19
        label.frame.origin = NSPoint(x: 20, y: (size.height - label.frame.height) / 2)
        bg.addSubview(label)
        p.contentView = bg
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            p.setFrame(NSRect(x: f.midX - size.width / 2, y: f.maxY - 64, width: size.width, height: size.height), display: true)
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        work?.cancel()
        let w = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }
}

/// 鼠标所在的屏幕
func mouseScreen() -> NSScreen? {
    NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
}
