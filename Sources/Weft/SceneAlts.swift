import AppKit
import ServiceManagement
import SwiftUI
import WeftCore

// MARK: - 「它也在这些场景里」
//
// 点 Dock / ⌘Tab 切到一个窗口，它在好几个存好的场景里（比如 Codex 既在「写代码」又在「接口排查」）：
// 先去最近用的那个（不让你等），屏幕顶上浮出一排「也在」，点一下换过去；不理它 4 秒后自己收起。

@MainActor
final class SceneAltState: ObservableObject {
    @Published var window: WindowInfo?
    @Published var current: WorkContext?
    @Published var alts: [WorkContext] = []
    @Published var remaining: Double = 1
}

@MainActor
final class SceneAltCard {
    let model: AppModel
    private var panel: KeyPanel?
    private var timer: Timer?
    private var display = ""
    let state = SceneAltState()

    init(model: AppModel) { self.model = model }

    func show(_ w: WindowInfo, _ alts: [WorkContext], on u: String) {
        guard !alts.isEmpty, let d = model.profile.display(uuid: u) else { return }
        display = u
        state.window = w
        state.current = model.showingScene[u].flatMap { id in model.contexts.first { $0.id == id } }
        state.alts = alts
        state.remaining = 1
        let p = panel ?? KeyPanel.make(level: .popUpMenu)
        p.contentView = FirstClickHostingView(rootView: SceneAltView(model: model, state: state,
            pick: { [weak self] c in self?.pick(c) }, close: { [weak self] in self?.hide() }))
        panel = p
        let fit = p.contentView?.fittingSize ?? NSSize(width: 420, height: 70)
        let primaryH = NSScreen.screens.first?.frame.height ?? d.frame.height
        let top = primaryH - d.visible.minY
        p.setFrame(NSRect(x: d.frame.midX - fit.width / 2, y: top - fit.height - 6, width: fit.width, height: fit.height), display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel else { return }
                if p.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation) { return }
                self.state.remaining -= 0.05 / 4
                if self.state.remaining <= 0 { self.hide() }
            }
        }
    }

    private func pick(_ c: WorkContext) {
        let u = display, w = state.window
        hide()
        model.switchScene(c, on: model.belongs(c, to: u) ? u : nil)
        if let w {
            if model.stage.stackLocate(w.id) != nil { model.stage.raiseInStack(w.id) }
            model.system.focus(w.id)
        }
    }

    func hide() {
        timer?.invalidate(); timer = nil
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }
}

struct SceneAltView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SceneAltState
    var pick: (WorkContext) -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let w = state.window { Image(nsImage: appIcon(w.pid)).resizable().frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 1) {
                Text("\(state.window.map { model.windowName($0) } ?? "")也在这些场景里").font(.system(size: 12, weight: .bold))
                Text(state.current.map { "先切到了「\($0.emoji) \($0.name)」· 点一个换过去" } ?? "点一个换过去").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(state.alts) { c in
                Button { pick(c) } label: {
                    Text("\(c.emoji) \(c.name)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(Color.purple.opacity(0.35)))
                }.buttonStyle(.plain)
            }
            Button { close() } label: {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.15), lineWidth: 2)
                    Circle().trim(from: 0, to: state.remaining).stroke(Color.purple, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                }.frame(width: 16, height: 16)
            }.buttonStyle(.plain).help("就在这个场景")
        }
        .fixedSize()
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.purple.opacity(0.5)))
        .padding(6)
    }
}

// MARK: - 开机自动启动

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            Toast.show("没设成：\(error.localizedDescription) · 可以在 系统设置 › 通用 › 登录项 里手动加", seconds: 3)
            return false
        }
    }
}

// MARK: - 窗口的名字

extension AppModel {
    /// 窗口在 Weft 里叫什么：不跟着标题变（Claude、Codex 的标题是当前对话名，浏览器是当前标签页，一变你就认不出了）。
    /// - 这个 App 只开着一个窗口：就叫 App 名
    /// - 好几个窗口：它在你的场景里就带上场景名（「Codex · 写代码」）；没进场景的按打开先后编号（「Chrome 2」）
    /// 现在的标题放在副标题里
    func windowName(_ w: WindowInfo) -> String {
        let same = windows.filter { $0.bundleID == w.bundleID }.sorted { $0.id < $1.id }
        guard same.count > 1 else { return w.appName }
        if let sc = scenes.first(where: { !isBlank($0.id) && sceneWindowSet($0, sureOnly: true).contains(w.id) }) ?? bestScene(containing: w) {
            let siblings = same.filter { $0.id != w.id && sceneWindowSet(sc).contains($0.id) }
            if siblings.isEmpty { return "\(w.appName) · \(sc.name)" }
        }
        let i = same.firstIndex { $0.id == w.id } ?? 0
        return "\(w.appName) \(i + 1)"
    }

    /// 副标题：现在的标题（和名字一样就不重复）
    func windowDetail(_ w: WindowInfo) -> String {
        let t = w.title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == w.appName ? "" : t
    }
}
