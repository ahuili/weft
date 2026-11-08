import AppKit
import SwiftUI
import WeftAI
import WeftCore

/// AI 排布面板：习惯搭配（即时）+ AI 给出的 1~3 套方案，每套都画成屏幕缩略图
struct ArrangeSheet: View {
    @ObservedObject var model: AppModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("排布建议").font(.system(size: 18, weight: .bold))
                Text("每块屏只留最该同时看到的窗口，其余退到后台").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !model.arranging && model.aiConfig.isConfigured {
                    Button { model.arrange() } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                }
                Button { model.arrangeVisible = false } label: { Image(systemName: "xmark") }.keyboardShortcut(.cancelAction)
            }
            .buttonStyle(.borderless)

            if let (a, b) = model.habitPair() { habitCard(a, b) }

            if model.arranging {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("AI 正在看你的窗口、屏幕和切换习惯…（\(model.modelLabel())，视模型 20~90 秒；不想等可以先用上面的习惯搭配）").foregroundStyle(.secondary)
                }
                .padding(.vertical, 30).frame(maxWidth: .infinity)
            } else if let opts = model.arrangeOptions, !opts.isEmpty {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(opts) { o in optionCard(o) }
                }
            }
            if let msg = model.arrangeMessage {
                HStack {
                    Image(systemName: "info.circle").foregroundStyle(.orange)
                    Text(msg).foregroundStyle(.secondary)
                    if !model.aiConfig.isConfigured {
                        Button("去选模型") { close(); NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: "ai") }
                    }
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    }

    func habitCard(_ a: WindowInfo, _ b: WindowInfo) -> some View {
        HStack(spacing: 12) {
            Text("🤝").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("习惯搭配（不用 AI）").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                Text("你经常在「\(model.short(a))」和「\(model.short(b))」之间来回切").font(.system(size: 13))
            }
            Spacer()
            Button("左右并排") { close(); model.pairUp(a, b) }.buttonStyle(.borderedProminent).tint(.purple)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.purple.opacity(0.10)))
    }

    func optionCard(_ o: ArrangementOption) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(o.name).font(.system(size: 15, weight: .bold))
            if !o.summary.isEmpty {
                Text(o.summary).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            SceneMap(model: model, scenes: o.scenes).frame(height: 150)
            HStack {
                Button { close(); model.applyArrangement(o, stageMode: true) } label: { Label("进入舞台", systemImage: "theatermasks") }
                    .buttonStyle(.borderedProminent).tint(.purple).help("按方案摆好，其余窗口退到后台")
                Button("只摆放") { close(); model.applyArrangement(o, stageMode: false) }
                    .help("按方案摆好，其余窗口不动（可 ⌘Z 撤销）")
            }
        }
        .padding(14)
        .frame(maxWidth: 380, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.10)))
    }
}

/// 把方案画成「屏幕缩略图」：按真实比例摆出每块屏幕和窗口位置
struct SceneMap: View {
    @ObservedObject var model: AppModel
    let scenes: [ArrangedScene]

    var body: some View {
        GeometryReader { g in
            let ds = model.profile.displays
            let union = ds.reduce(CGRect.null) { $0.union($1.frame) }
            let scale = union.isNull ? 1 : min(g.size.width / union.width, g.size.height / union.height)
            let ox = (g.size.width - union.width * scale) / 2, oy = (g.size.height - union.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(Array(ds.enumerated()), id: \.offset) { i, d in
                    let dr = CGRect(x: (d.frame.minX - union.minX) * scale + ox, y: (d.frame.minY - union.minY) * scale + oy,
                                    width: d.frame.width * scale, height: d.frame.height * scale)
                    RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.35))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.2)))
                        .frame(width: dr.width, height: dr.height).offset(x: dr.minX, y: dr.minY)
                    if let s = scenes.first(where: { $0.displayIndex == i }) {
                        let frames = StageGeometry.frames(s.spec, in: d.visible, gap: 12)
                        ForEach(Array(s.windowIDs.enumerated()), id: \.offset) { j, id in
                            if j < frames.count, let w = model.window(id) {
                                let f = frames[j]
                                let r = CGRect(x: (f.minX - union.minX) * scale + ox, y: (f.minY - union.minY) * scale + oy,
                                               width: f.width * scale, height: f.height * scale)
                                slot(w, main: j == 0).frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
                            }
                        }
                    } else {
                        Text("不放").font(.system(size: 10)).foregroundStyle(.tertiary)
                            .frame(width: dr.width, height: dr.height).offset(x: dr.minX, y: dr.minY)
                    }
                }
            }
        }
    }

    func slot(_ w: WindowInfo, main: Bool) -> some View {
        ZStack {
            if let t = model.thumbs[w.id] {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fill).opacity(0.55)
            }
            VStack(spacing: 3) {
                Image(nsImage: appIcon(w.pid)).resizable().frame(width: 18, height: 18).shadow(radius: 2)
                Text(model.short(w)).font(.system(size: 9, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                    .padding(.horizontal, 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(main ? Color.purple.opacity(0.45) : Color.blue.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(main ? 0.6 : 0.3)))
    }
}
