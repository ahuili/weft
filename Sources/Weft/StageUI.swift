import AppKit
import SwiftUI
import WeftCore

/// 舞台模式的「幕布」：一层毛玻璃盖住桌面图标和壁纸，只在所有普通窗口下面。
/// 它会吃掉点击，避免点到桌面触发「点按墙纸显示桌面」把窗口全部推开。
@MainActor
final class Curtain {
    private var panels: [NSPanel] = []
    var hint = ""

    var isShown: Bool { !panels.isEmpty }

    func show() {
        hide(animated: false)
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        for s in NSScreen.screens {
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = level
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            p.contentView = NSHostingView(rootView: CurtainView(hint: hint))
            p.setFrame(s.frame, display: true)
            p.alphaValue = 0
            p.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; p.animator().alphaValue = 1 }
            panels.append(p)
        }
    }

    func hide(animated: Bool = true) {
        let old = panels
        panels.removeAll()
        guard animated else { old.forEach { $0.orderOut(nil) }; return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; old.forEach { $0.animator().alphaValue = 0 } }) {
            old.forEach { $0.orderOut(nil) }
        }
    }
}

struct CurtainView: View {
    let hint: String
    var body: some View {
        ZStack(alignment: .bottom) {
            Glass(material: .underWindowBackground)
            LinearGradient(colors: [.black.opacity(0.25), .purple.opacity(0.10), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            Text(hint).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.35)).padding(.bottom, 26)
        }
        .ignoresSafeArea()
    }
}

/// 版式小图标：直接用真实的几何计算画出来
struct LayoutIcon: View {
    let spec: StageSpec
    var selected = false
    var size = CGSize(width: 30, height: 20)

    var body: some View {
        let frames = StageGeometry.frames(spec, in: CGRect(origin: .zero, size: CGSize(width: size.width * 10, height: size.height * 10)), gap: 14)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
            ForEach(Array(frames.enumerated()), id: \.offset) { i, f in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i == 0 ? (selected ? Color.purple : Color.primary.opacity(0.7)) : Color.primary.opacity(selected ? 0.45 : 0.3))
                    .frame(width: f.width / 10, height: f.height / 10)
                    .offset(x: f.minX / 10, y: f.minY / 10)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// 舞台控制条：换版式、调比例、主副互换、退出
struct StageBar: View {
    @ObservedObject var model: AppModel
    var compact = false

    var body: some View {
        let cur = model.currentStage
        let _ = model.stageRevision
        VStack(alignment: .leading, spacing: 6) {
        if model.stageDisplays.count > 1 {
            let u = model.stage.currentDisplay()
            HStack(spacing: 4) {
                Image(systemName: "display.2").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(model.stageDisplays, id: \.uuid) { d in
                    Button { model.selectStageDisplay(d.uuid) } label: {
                        Text(d.name).font(.system(size: 11, weight: d.uuid == u ? .bold : .regular))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(d.uuid == u ? Color.purple.opacity(0.3) : Color.white.opacity(0.06)))
                    }.buttonStyle(.plain).help("下面的版式只作用于这块屏幕，每块屏的舞台互不影响")
                }
                Text("各屏独立").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        HStack(spacing: compact ? 4 : 8) {
            ForEach(StageLayout.allCases, id: \.self) { l in
                let sel = cur?.spec.layout == l
                Button { model.setStageLayout(l) } label: {
                    LayoutIcon(spec: sel ? cur!.spec : StageSpec(l), selected: sel,
                               size: compact ? CGSize(width: 24, height: 16) : CGSize(width: 30, height: 20))
                        .padding(5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Color.purple.opacity(0.22) : Color.clear))
                }
                .buttonStyle(.plain).help(l.title)
            }
            if let spec = cur?.spec, !spec.ratioChoices.isEmpty {
                Divider().frame(height: 18)
                Button { model.cycleStageRatio() } label: {
                    Text(spec.ratioLabel).font(.system(size: 11, weight: .semibold, design: .rounded)).frame(minWidth: 30)
                }.buttonStyle(.bordered).controlSize(.small).help("切换比例")
                if spec.layout != .triple {
                    Button { model.mirrorStage() } label: { Image(systemName: "arrow.left.and.right") }
                        .buttonStyle(.bordered).controlSize(.small).help("主窗口换到另一边")
                }
                Button { model.swapStage() } label: { Image(systemName: "arrow.triangle.swap") }
                    .buttonStyle(.bordered).controlSize(.small).help("主位和副位互换")
            }
            if !compact {
                Spacer(minLength: 8)
                Button { model.exitStage() } label: { Label("退出舞台", systemImage: "xmark.circle") }
                    .buttonStyle(.bordered).controlSize(.small)
            }
        }
        }
    }
}

/// 侧栏里的舞台面板（侧栏只有 276 宽，一行放不下就分行；每个格子一行，看得清、点得到）
struct ShelfStagePanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let _ = model.stageRevision
        let u = model.stage.currentDisplay() ?? ""
        let st = model.currentStage
        VStack(alignment: .leading, spacing: 8) {
            // 第一行：哪块屏 · 撤销 · 归位
            HStack(spacing: 4) {
                if model.stageDisplays.count > 1 {
                    ForEach(model.stageDisplays, id: \.uuid) { d in
                        Button { model.selectStageDisplay(d.uuid) } label: {
                            Text(String(d.name.prefix(8))).font(.system(size: 11, weight: d.uuid == u ? .bold : .regular)).lineLimit(1)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Capsule().fill(d.uuid == u ? Color.purple.opacity(0.3) : Color.white.opacity(0.06)))
                        }.buttonStyle(.plain).help("下面的操作只作用于这块屏幕")
                    }
                } else {
                    Text("🎭 舞台").font(.system(size: 11, weight: .bold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { model.undoStage() } label: { Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(model.stage.canUndo ? .primary : .tertiary).disabled(!model.stage.canUndo)
                    .help("撤销上一步（换了谁、换了版式、拖了位置）")
                Button { model.healStage() } label: {
                    Label("归位", systemImage: "sparkles").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                }.buttonStyle(.plain).help("乱了就点：每个窗口回自己的格子，跑出来的后台窗口藏回去")
            }
            // 第二行：版式
            HStack(spacing: 0) {
                ForEach(StageLayout.allCases, id: \.self) { l in
                    let sel = st?.spec.layout == l
                    Button { model.setStageLayout(l) } label: {
                        LayoutIcon(spec: sel ? st!.spec : StageSpec(l), selected: sel, size: CGSize(width: 26, height: 17))
                            .padding(5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Color.purple.opacity(0.22) : Color.clear))
                    }
                    .buttonStyle(.plain).help(l.title).frame(maxWidth: .infinity)
                }
            }
            // 第三行：比例 · 翻转 · 互换（有的版式才有）
            if let spec = st?.spec, !spec.ratioChoices.isEmpty {
                HStack(spacing: 6) {
                    Button { model.cycleStageRatio() } label: {
                        Label(spec.ratioLabel, systemImage: "rectangle.split.2x1").font(.system(size: 11, weight: .semibold, design: .rounded))
                    }.help("换比例（也可以直接拉两个窗口中间的边）")
                    if spec.layout != .triple {
                        Button { model.mirrorStage() } label: { Image(systemName: "arrow.left.and.right") }.help("主窗口换到另一边")
                    }
                    Button { model.swapStage() } label: { Image(systemName: "arrow.triangle.swap") }.help("主位和副位互换")
                    Spacer(minLength: 0)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            // 每个格子一行
            VStack(spacing: 3) {
                ForEach(Array((st?.slots ?? []).enumerated()), id: \.offset) { i, id in
                    slotRow(u, i, id.flatMap { model.window($0) }, locked: st?.locked.contains(i) == true, active: st?.active == i)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func slotRow(_ u: String, _ i: Int, _ w: WindowInfo?, locked: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            Text(i == 0 ? "主" : "\(i + 1)").font(.system(size: 9, weight: .heavy, design: .rounded))
                .frame(width: 16, height: 16)
                .background(Circle().fill(i == 0 ? Color.purple.opacity(0.8) : Color.white.opacity(0.15)))
            if let w {
                Image(nsImage: appIcon(w.pid)).resizable().frame(width: 15, height: 15)
                Text(model.short(w)).font(.system(size: 11, weight: active ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
            } else {
                Text("空格子 · 点 ⟳ 选一个").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 2)
            Button { model.onPickSlot(u, i) } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                .help(w == nil ? "选一个窗口放进来" : "换一个（在屏幕上这个格子里弹出候选）")
            Button { model.toggleSlotLock(display: u, slot: i) } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }
                .foregroundStyle(locked ? Color.purple : Color.secondary).help("锁住：⌘Tab 切来的窗口不会换掉它")
            if w != nil {
                Button { model.clearStageSlot(display: u, slot: i) } label: { Image(systemName: "xmark") }.help("请下台（格子空出来）")
            }
        }
        .buttonStyle(.plain).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(active && w != nil ? Color.purple.opacity(0.18) : Color.white.opacity(0.05)))
    }
}
