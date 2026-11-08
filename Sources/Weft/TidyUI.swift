import AppKit
import SwiftUI
import WeftAI
import WeftCore

/// 整理面板：按类别列出建议，勾选后一键执行
struct TidySheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let items = model.tidyItems
        let order: [TidyKind] = [.empty, .duplicate, .ai, .stale, .idleApp]
        let picked = items.filter(\.checked)
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("🧹").font(.system(size: 20))
                Text("整理桌面").font(.system(size: 18, weight: .bold))
                Text(headline(items)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { model.tidyVisible = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            DeskCard(model: model)
            SceneCard(model: model)
            Text("清理").font(.system(size: 13, weight: .bold)).padding(.top, 4)
            if model.tidyThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("AI 正在逐个看窗口，判断哪些事已经办完…（规则建议已经可以先用）").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if let s = model.tidySummary {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").foregroundStyle(.purple)
                    Text(s).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if !model.aiConfig.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("下面是规则判断。配一个 AI 模型还能识别「已经查完的搜索页、办完的事」。").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("去配置") { model.tidyVisible = false; NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: "ai") }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }

            if items.isEmpty && !model.tidyThinking {
                HStack(spacing: 8) {
                    Text("✨")
                    Text("没有空窗口、重复窗口要清理").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(order, id: \.self) { k in
                        let group = items.filter { $0.kind == k }
                        if !group.isEmpty { section(k, group) }
                    }
                }
            }
            }
            }
            .frame(maxHeight: 620)

            HStack {
                Text("关闭窗口时，有未保存内容的 App 会自己问你；「收进后台」不关闭，随时能在侧栏叫回。")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("全不选") { for i in model.tidyItems.indices { model.tidyItems[i].checked = false } }
                    .disabled(picked.isEmpty)
                Button { model.runTidy() } label: { Text(picked.isEmpty ? "清理" : "清理选中的 \(picked.count) 项").frame(minWidth: 120) }
                    .buttonStyle(.borderedProminent).tint(.purple).keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(22)
        .frame(maxWidth: 820)
        .background(RoundedRectangle(cornerRadius: 18).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
    }

    func headline(_ items: [TidyItem]) -> String {
        let w = items.filter { $0.windowID != nil }.count, a = items.count - w
        if items.isEmpty { return "" }
        return [w > 0 ? "\(w) 个窗口" : nil, a > 0 ? "\(a) 个 App" : nil].compactMap { $0 }.joined(separator: "、") + "可以整理"
    }

    func section(_ k: TidyKind, _ group: [TidyItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(k.title).font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                Text("\(group.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
                Spacer()
                let all = group.allSatisfy(\.checked)
                Button(all ? "取消这组" : "选中这组") {
                    for it in group { if let i = model.tidyItems.firstIndex(where: { $0.id == it.id }) { model.tidyItems[i].checked = !all } }
                }.buttonStyle(.link).font(.system(size: 11))
            }
            ForEach(group) { it in row(it) }
        }
    }

    func row(_ it: TidyItem) -> some View {
        let idx = model.tidyItems.firstIndex { $0.id == it.id }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { idx.map { model.tidyItems[$0].checked } ?? false },
                                     set: { v in if let i = idx { model.tidyItems[i].checked = v } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(nsImage: appIcon(it.pid)).resizable().frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(it.windowID == nil ? it.appName : "\(it.appName) · \(it.title)").font(.system(size: 13)).lineLimit(1)
                Text(it.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if it.windowID != nil {
                Menu {
                    ForEach([TidyAction.close, .stash, .minimize], id: \.self) { a in
                        Button(a.title) { if let i = idx { model.tidyItems[i].action = a; model.tidyItems[i].checked = true } }
                    }
                } label: { Text(it.action.title).font(.system(size: 11, weight: .medium)) }
                    .menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(it.action == .close ? .red : .primary)
                Button { if let id = it.windowID, let w = model.window(id) { model.tidyVisible = false; model.focus(w) } } label: {
                    Image(systemName: "eye")
                }.buttonStyle(.borderless).help("先看一眼这个窗口")
            } else {
                Text(it.action.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(it.checked ? Color.purple.opacity(0.10) : Color.white.opacity(0.04)))
    }
}


// MARK: - 桌面

/// 每块屏的桌面一览：空桌面虚线框，当前桌面高亮；可以一键删掉空桌面，或合并成一个桌面
struct DeskCard: View {
    @ObservedObject var model: AppModel
    @State private var confirmMerge = false

    var body: some View {
        let map = model.deskMap
        let empty = map.reduce(0) { $0 + $1.spaces.filter { $0.isEmpty && !$0.isCurrent }.count }
        let extra = map.reduce(0) { $0 + $1.spaces.filter { !$0.isCurrent && !$0.isFullscreen }.count }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("桌面").font(.system(size: 13, weight: .bold))
                Text(map.isEmpty ? "" : "\(map.reduce(0) { $0 + $1.spaces.count }) 个桌面，\(empty) 个是空的")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if model.deskBusy { ProgressView().controlSize(.small) }
                Button("删掉 \(empty) 个空桌面") { model.removeEmptyDesktops() }
                    .disabled(empty == 0 || model.deskBusy)
                Button("合并成每屏 1 个") { confirmMerge = true }
                    .disabled(extra == 0 || model.deskBusy)
                    .help("把每块屏的其他桌面都删掉，上面的窗口会自动挪到当前桌面（不会关闭）。以后用 Weft 的场景来切换，不用再翻桌面")
            }
            ForEach(map) { d in
                HStack(alignment: .top, spacing: 8) {
                    Text(d.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(d.spaces) { sp in tile(sp) }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
        .alert("合并桌面？", isPresented: $confirmMerge) {
            Button("合并", role: .destructive) { model.mergeDesktops() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会打开调度中心，删掉每块屏除当前桌面以外的 \(extra) 个桌面。上面的窗口由系统挪到剩下的桌面，不会关闭任何窗口。")
        }
    }

    func tile(_ sp: DeskSpace) -> some View {
        VStack(spacing: 3) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(sp.isCurrent ? Color.purple.opacity(0.3) : Color.white.opacity(sp.isEmpty ? 0.02 : 0.08))
                if sp.isEmpty {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(.secondary.opacity(0.5))
                } else {
                    HStack(spacing: -4) {
                        ForEach(Array(sp.windows.prefix(3).enumerated()), id: \.offset) { _, w in
                            Image(nsImage: appIcon(w.pid)).resizable().frame(width: 16, height: 16)
                        }
                        if sp.windows.count > 3 { Text("+\(sp.windows.count - 3)").font(.system(size: 9)).padding(.leading, 6) }
                    }
                }
            }
            .frame(width: 64, height: 36)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(sp.isCurrent ? Color.purple : .clear, lineWidth: 1.5))
            Text(sp.isFullscreen ? "全屏" : "\(sp.index)").font(.system(size: 9)).foregroundStyle(sp.isCurrent ? .primary : .secondary)
        }
        .help(sp.windows.isEmpty ? "桌面 \(sp.index)：空的" : "桌面 \(sp.index)：" + sp.windows.map { $0.appName }.joined(separator: "、"))
    }
}

// MARK: - AI 输入框

/// 给 AI 提要求的输入框：一个圆角卡片，左边 ✨，右边发送键；回车也能发。聚焦时描一圈紫色渐变
struct AIAskBox: View {
    @ObservedObject var model: AppModel
    var placeholder = "说说想怎么分（可以不写）"
    var fontSize: CGFloat = 11
    @FocusState private var focused: Bool

    static let tint = LinearGradient(colors: [Color(red: 0.62, green: 0.36, blue: 0.98), Color(red: 0.93, green: 0.38, blue: 0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: fontSize + 2, weight: .semibold))
                .foregroundStyle(Self.tint)
                .padding(.bottom, 1)
            TextField("", text: $model.organizeRequest, prompt: Text(placeholder).foregroundColor(.secondary.opacity(0.8)), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: fontSize))
                .lineLimit(1...5)
                .focused($focused)
                .disabled(model.organizing)
                .onSubmit { if !model.organizing { model.organize() } }
            Button { model.organize() } label: {
                ZStack {
                    Circle().fill(Self.tint).opacity(model.organizing ? 0.5 : 1)
                    if model.organizing {
                        ProgressView().controlSize(.mini).tint(.white)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .heavy)).foregroundStyle(.white)
                    }
                }
                .frame(width: 22, height: 22)
                .shadow(color: .purple.opacity(0.35), radius: 3, y: 1)
            }
            .buttonStyle(.plain).disabled(model.organizing)
            .help(model.organizing ? "AI 正在看你的窗口…" : "让 AI 按这个意思建一批场景（回车也行）")
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.primary.opacity(focused ? 0.07 : 0.045)))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(focused ? AnyShapeStyle(Self.tint) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: focused ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - 场景

/// AI 把窗口整理成几个场景，每个场景带版式预览；可以先「试摆」看看，满意再保存
struct SceneCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("场景").font(.system(size: 13, weight: .bold))
                Text("一组要同时看的窗口，一键摆上屏幕（其余退到后台）").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if model.organizing {
                    ProgressView().controlSize(.small)
                    Text("AI 正在看所有桌面上的窗口…").font(.system(size: 12)).foregroundStyle(.secondary)
                } else if model.aiConfig.isConfigured {
                    Button(model.proposal == nil ? "AI 整理成场景" : "重新整理") { model.organize() }
                } else {
                    Button("配置 AI 后可用") { model.tidyVisible = false; NotificationCenter.default.post(name: .init("WeftOpenSettings"), object: "ai") }
                        .buttonStyle(.link)
                }
            }
            if model.aiConfig.isConfigured {
                AIAskBox(model: model, placeholder: "说说想怎么分，可以不写 · 比如：Claude 有时单独、有时配微信；浏览器几个窗口分开放", fontSize: 12)
            }
            if let s = model.deskSummary, model.proposal != nil {
                HStack(spacing: 6) { Image(systemName: "sparkles").foregroundStyle(.purple); Text(s).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if let msg = model.aiMessage, !model.organizing {
                Text(msg).font(.system(size: 12)).foregroundStyle(.orange)
            }
            if let p = model.proposal, !p.isEmpty {
                ForEach(Array(p.enumerated()), id: \.offset) { _, prop in row(prop) }
                FloatingSuggestion(model: model)
                HStack {
                    Spacer()
                    Button("不要了") { model.discardProposal() }
                    Button("保存这 \(p.count) 个场景") { model.acceptProposal() }.buttonStyle(.borderedProminent).tint(.purple)
                }
            } else if model.proposal == nil && !model.contexts.filter({ $0.plan != nil }).isEmpty {
                // 已保存的场景
                ForEach(model.contexts.filter { $0.plan != nil }) { c in
                    HStack(spacing: 10) {
                        Text("\(c.emoji) \(c.name)").font(.system(size: 13, weight: .semibold))
                        ForEach(Array((c.plan ?? []).enumerated()), id: \.offset) { _, pl in
                            LayoutIcon(spec: pl.spec, size: CGSize(width: 30, height: 20))
                        }
                        Spacer()
                        Button("摆出来") { model.tidyVisible = false; model.enter(c) }
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    func row(_ p: ContextProposal) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(p.emoji) \(p.name)").font(.system(size: 13, weight: .semibold))
                Text(p.reason).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(width: 220, alignment: .leading)
            ForEach(Array(p.scenes.enumerated()), id: \.offset) { _, sc in
                VStack(spacing: 3) {
                    LayoutPreview(model: model, spec: sc.spec, windows: sc.windowIDs, size: CGSize(width: 92, height: 58))
                    Text(model.profile.displays.indices.contains(sc.displayIndex) ? (model.profile.displays[sc.displayIndex].isBuiltin ? "笔记本" : "外接屏") : "")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("试摆") { model.tidyVisible = false; model.tryProposal(p) }
                .help("现在就按这个场景摆上屏幕看看（其他窗口退到后台，退出舞台全部还原）")
            Button { model.dropProposal(p.name) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary).help("这个不要")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}


/// AI 建议设成随手窗口的 App：点 ✕ 去掉不同意的
struct FloatingSuggestion: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if !model.proposedFloating.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("🪶 随手窗口").font(.system(size: 12, weight: .semibold))
                    ForEach(model.proposedFloating, id: \.self) { b in
                        HStack(spacing: 3) {
                            Text(model.appName(bundleID: b)).font(.system(size: 11))
                            Button { model.proposedFloating.removeAll { $0 == b } } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                Text((model.floatingReason.isEmpty ? "" : model.floatingReason + " · ") + "不进场景、不占格子、切场景时不藏，原样浮在上面").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
