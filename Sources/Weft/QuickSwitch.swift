import AppKit
import Carbon
import SwiftUI
import WeftCore

/// ⌥Tab：和 ⌘Tab 一样的手感，但按「窗口」而不是按「App」，顺序来自你真实的使用顺序。
@MainActor
final class QuickSwitchState: ObservableObject {
    @Published var items: [WindowInfo] = []
    @Published var index = 0
}

struct QuickSwitchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: QuickSwitchState

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                ForEach(Array(state.items.enumerated()), id: \.element.id) { i, w in
                    WindowCard(window: w, thumb: model.thumbs[w.id], selected: i == state.index,
                               accent: .accentColor, subtitle: w.appName, width: 196)
                }
            }
            if state.items.indices.contains(state.index) {
                let w = state.items[state.index]
                HStack(spacing: 8) {
                    Text(w.title.isEmpty ? w.appName : w.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let l = model.labels[w.id] { Text(l).font(.system(size: 12)).foregroundStyle(.secondary) }
                    if let s = model.slotLabel(w.id) {
                        Text("下次直接 \(s)").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.purple.opacity(0.35)))
                    }
                    if model.stageActive {
                        Text(model.stage.isOnStage(w.id) ? "台上" : "上台").font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(.purple.opacity(0.35)))
                    }
                }
            }
        }
        .padding(24)
        .background(RoundedRectangle(cornerRadius: 24).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.12)))
    }
}

@MainActor
final class QuickSwitchController {
    let model: AppModel
    let state = QuickSwitchState()
    private var panel: KeyPanel?
    private var monitors: [Any] = []
    private var all: [WindowInfo] = []
    private var offset = 0
    private let visible = 7
    /// 按住的修饰键（默认 ⌥），松开即切换
    private var hold: NSEvent.ModifierFlags = .option

    init(model: AppModel) { self.model = model }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// 每次 ⌥Tab（或 ⌥⇧Tab）都会调用
    func step(_ d: Int, hold: NSEvent.ModifierFlags = .option) {
        if !isVisible { self.hold = hold.isEmpty ? .option : hold; open(); return }
        let n = all.count
        guard n > 0 else { return }
        var global = (offset + state.index + d + n) % n
        if global < 0 { global += n }
        layout(global)
    }

    private func open() {
        model.refresh(captureThumbs: false)
        all = model.mruOrder()
        guard all.count > 0 else { Toast.show("没有可切换的窗口"); return }
        model.thumbnails.refresh(Array(all.prefix(12).map(\.id)), maxWidth: 400) { [weak self] new in
            self?.model.thumbs.merge(new) { $1 }
        }
        layout(all.count > 1 ? 1 : 0)
        let p = KeyPanel.make(level: .popUpMenu)
        p.contentView = NSHostingView(rootView: QuickSwitchView(model: model, state: state))
        panel = p
        resize()
        p.makeKeyAndOrderFront(nil)
        // 松开 ⌥ 即切换；esc 取消
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            self?.handle(e) ?? e
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            Task { @MainActor in _ = self?.handle(e) }
        } as Any)
        // 快速点按 ⌥Tab 时 ⌥ 可能已经松开：直接切到上一个窗口
        if !NSEvent.modifierFlags.contains(hold) { commit() }
    }

    private func layout(_ global: Int) {
        // 选中项始终在可视窗口内
        if global < offset { offset = global }
        if global >= offset + visible { offset = global - visible + 1 }
        state.items = Array(all[offset..<min(all.count, offset + visible)])
        state.index = global - offset
        resize()
    }

    private func resize() {
        guard let p = panel, let screen = mouseScreen() else { return }
        let w = CGFloat(state.items.count) * 212 + 32
        let h: CGFloat = 230
        p.setFrame(NSRect(x: screen.frame.midX - w / 2, y: screen.frame.midY - h / 2 + 60, width: w, height: h), display: true)
    }

    private func handle(_ e: NSEvent) -> NSEvent? {
        if e.type == .flagsChanged && !e.modifierFlags.contains(hold) { commit(); return e }
        if e.type == .keyDown {
            switch Int(e.keyCode) {
            case kVK_Escape: close(); return nil
            case kVK_Return: commit(); return nil
            case kVK_LeftArrow: step(-1); return nil
            case kVK_RightArrow: step(1); return nil
            default: return e
            }
        }
        return e
    }

    private func commit() {
        guard isVisible else { return }
        let target = state.items.indices.contains(state.index) ? state.items[state.index] : nil
        close()
        if let target { model.focus(target) }
    }

    private func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
        offset = 0
    }
}
