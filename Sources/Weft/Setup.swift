import AppKit
import SwiftUI
import WeftAI
import WeftCore

// 首次安装的引导 + 之后的设置窗口：同一套页面。
// 引导模式按步骤走（欢迎 → 权限 → 快捷键 → AI → 舞台与侧栏 → 完成），设置模式用顶部标签页切换。

enum SetupPage: String, CaseIterable, Identifiable {
    case welcome, permissions, keys, ai, stage, memory, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .permissions: return "权限"
        case .keys: return "快捷键"
        case .ai: return "AI 模型"
        case .stage: return "舞台与侧栏"
        case .memory: return "记忆"
        case .done: return "完成"
        }
    }
    static let settingsTabs: [SetupPage] = [.keys, .ai, .memory, .stage, .permissions]
}

@MainActor
final class PermissionState: ObservableObject {
    @Published var ax = Permissions.accessibility
    @Published var screen = Permissions.screenCapture
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.ax = Permissions.accessibility
                self?.screen = Permissions.screenCapture
            }
        }
    }
}

@MainActor
final class SetupState: ObservableObject {
    @Published var page: SetupPage = .welcome
    @Published var wizard = true
    /// 最近一次检测到的双击（实时测试用）
    @Published var detected: ModKey?
    @Published var detectedAt = Date.distantPast
    @Published var recording: String?   // 正在录制哪个功能
    @Published var bindFailures: [String] = []

    // AI 草稿
    @Published var providerID: String?
    @Published var baseURL = ""
    @Published var apiKey = ""
    @Published var modelID = ""
    @Published var models: [ModelEntry] = []
    @Published var loadingModels = false
    @Published var testResult: String?
    @Published var testing = false
    @Published var magpieUp = false

    func loadAI(_ c: AIConfig) {
        providerID = c.provider
        baseURL = c.baseURL
        apiKey = c.apiKey ?? ""
        modelID = c.model
        Task { @MainActor in self.magpieUp = await ModelDiscovery.magpieAvailable() }
        if c.isConfigured { fetchModels() }
    }

    func choose(_ p: AIProvider) {
        providerID = p.id
        baseURL = p.baseURL
        apiKey = Keychain.get(p.id) ?? ""
        modelID = ""
        models = []
        testResult = nil
        if !p.needsKey || !apiKey.isEmpty { fetchModels() }
    }

    func fetchModels() {
        guard !baseURL.isEmpty else { return }
        loadingModels = true
        let url = baseURL, key = apiKey
        Task { @MainActor in
            defer { self.loadingModels = false }
            do {
                let ms = try await ModelDiscovery.listModels(baseURL: url, apiKey: key, timeout: 6)
                self.models = ms.filter(\.supportsTools)
                if self.modelID.isEmpty || !ms.contains(where: { $0.id == self.modelID }) {
                    let suggested = AIProvider.find(self.providerID)?.suggested ?? []
                    self.modelID = suggested.first(where: { s in ms.contains { $0.id == s } }) ?? self.models.first?.id ?? suggested.first ?? ""
                }
            } catch {
                self.models = []
                if self.modelID.isEmpty { self.modelID = AIProvider.find(self.providerID)?.suggested.first ?? "" }
                self.testResult = "拉取模型列表失败：\(error)（可以手动填模型名）"
            }
        }
    }

    var draft: AIConfig { AIConfig(provider: providerID, baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey, model: modelID) }

    func test() {
        testing = true
        testResult = nil
        let cfg = draft
        Task { @MainActor in
            defer { self.testing = false }
            do {
                let t = try await ModelDiscovery.ping(cfg)
                self.testResult = String(format: "✓ 连接成功，响应 %.1f 秒", t)
            } catch {
                self.testResult = "✗ \(error)"
            }
        }
    }
}

struct SetupView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SetupState
    @ObservedObject var perms: PermissionState
    var finish: () -> Void
    var tryHub: () -> Void
    var tryShelf: () -> Void
    var relaunch: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if state.wizard { steps.padding(.top, 34).padding(.bottom, 6) } else { tabs.padding(.top, 34).padding(.bottom, 6) }
            Divider()
            ScrollView {
                Group {
                    switch state.page {
                    case .welcome: WelcomePane()
                    case .permissions: PermissionsPane(perms: perms, relaunch: relaunch)
                    case .keys: KeysPane(model: model, state: state)
                    case .ai: AIPane(model: model, state: state)
                    case .stage: StagePane(model: model, tryShelf: tryShelf)
                    case .memory: MemoryPane(model: model)
                    case .done: DonePane(model: model, tryHub: tryHub)
                    }
                }
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            if state.wizard {
                Divider()
                HStack {
                    if state.page != .welcome { Button("上一步") { go(-1) } }
                    Spacer()
                    if state.page == .ai && !model.aiConfig.isConfigured {
                        Button("跳过，先不用 AI") { state.providerID = nil; go(1) }
                    }
                    Button(state.page == .done ? "开始使用" : state.page == .ai && (state.providerID == nil || state.modelID.isEmpty) && !model.aiConfig.isConfigured ? "下一步（不用 AI）" : "下一步") {
                        if state.page == .ai { saveAI() }
                        if state.page == .done { finish() } else { go(1) }
                    }
                    .buttonStyle(.borderedProminent).tint(.purple).keyboardShortcut(.defaultAction)
                    .disabled(state.page == .permissions && !perms.ax)
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 640)
    }

    var steps: some View {
        HStack(spacing: 6) {
            ForEach(Array(SetupPage.allCases.enumerated()), id: \.element) { i, p in
                let cur = SetupPage.allCases.firstIndex(of: state.page) ?? 0
                HStack(spacing: 5) {
                    Circle().fill(i <= cur ? Color.purple : Color.secondary.opacity(0.3)).frame(width: 8, height: 8)
                    Text(p.title).font(.system(size: 12, weight: i == cur ? .bold : .regular)).foregroundStyle(i == cur ? .primary : .secondary)
                }
                if i < SetupPage.allCases.count - 1 { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 18, height: 1) }
            }
        }
    }

    var tabs: some View {
        Picker("", selection: $state.page) {
            ForEach(SetupPage.settingsTabs) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 420)
        .onChange(of: state.page) { old, _ in if old == .ai { saveAI() } }
    }

    func go(_ d: Int) {
        let all = SetupPage.allCases
        let i = (all.firstIndex(of: state.page) ?? 0) + d
        if all.indices.contains(i) { withAnimation(.easeOut(duration: 0.15)) { state.page = all[i] } }
    }

    func saveAI() {
        guard state.providerID != nil, !state.modelID.isEmpty else { return }
        model.aiConfig = state.draft
        model.aiConfig.save()
        model.refreshModels()
    }
}

// MARK: - 欢迎

struct WelcomePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Weft").font(.system(size: 30, weight: .heavy, design: .rounded))
                    Text("窗口开得再多，眼前也只留你现在要用的那几个").foregroundStyle(.secondary)
                    Text("Weft 是织布的「纬线」：它在经线间穿梭，把散乱的线织成一块布。").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            idea("theatermasks.fill", "舞台模式", "每块屏幕只「上台」1~3 个窗口，按版式排好；其余退到后台（不关闭、瞬间叫回）。你切到哪个窗口，它就上台。")
            idea("sidebar.left", "边缘后台", "鼠标碰屏幕边缘，滑出所有窗口：直接打字搜、按 App 叠放、悬停看大图，一点就上台。")
            idea("sparkle.magnifyingglass", "总控", "一个触发键打开全屏总控：拼音搜索、按「事情」分组、习惯推荐、AI 排布建议。")
            idea("brain", "会学习的 AI", "在本机学你的切换习惯（不上传）；需要时让 AI 把窗口归成「事情」、给出摆放方案，或帮你「整理」掉空窗口和办完的事。")
            Text("接下来 1 分钟：授权、选快捷键、选 AI 模型（可跳过）。").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    func idea(_ icon: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(.purple).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 权限

struct PermissionsPane: View {
    @ObservedObject var perms: PermissionState
    var relaunch: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("两项系统权限").font(.system(size: 18, weight: .bold))
            permRow(ok: perms.ax, title: "辅助功能（必需）", desc: "读取窗口标题、切换和摆放窗口", pane: "Privacy_Accessibility") { Permissions.requestAccessibility() }
            permRow(ok: perms.screen, title: "录屏与系统录音（推荐）", desc: "只截窗口画面做缩略图预览，不录制、不上传", pane: "Privacy_ScreenCapture") { Permissions.requestScreenCapture() }
            if !perms.ax || !perms.screen {
                VStack(alignment: .leading, spacing: 6) {
                    Text("已经打开开关，这里还显示未授权？").font(.system(size: 12, weight: .semibold))
                    Text("通常是系统里留着旧版本的授权记录：点「重置授权记录」，再到系统设置里重新打开 Weft 的开关。录屏权限打开后需要重启一次 Weft。")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("重置授权记录") { resetTCC() }
                        Button("重启 Weft", action: relaunch)
                    }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
            }
        }
    }

    func permRow(ok: Bool, title: String, desc: String, pane: String, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 22)).foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if ok { Text("已授权").foregroundStyle(.green).font(.system(size: 12, weight: .medium)) } else {
                Button("去授权") {
                    request()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }

    func resetTCC() {
        let id = Bundle.main.bundleIdentifier ?? "local.weft.app"
        for service in ["Accessibility", "ScreenCapture"] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            p.arguments = ["reset", service, id]
            try? p.run()
            p.waitUntilExit()
        }
        Permissions.requestAccessibility()
        Toast.show("已重置，请在系统设置里重新打开 Weft 的开关")
    }
}

// MARK: - 快捷键

struct KeysPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SetupState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选你顺手、又不和别的软件打架的触发方式").font(.system(size: 18, weight: .bold))
                Text("「双击」一个单独的修饰键最省事：右边的 ⌥、⌘ 平时几乎不单独按，很少冲突。选好后直接在键盘上试，下面会亮。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            tester
            TriggerPicker(state: state, title: "总控", desc: "全屏面板：搜索、事情、AI", trigger: binding(\.hubTrigger), allowDoubleTap: true)
            TriggerPicker(state: state, title: "舞台模式 开 / 关", desc: "只留当前要用的窗口", trigger: binding(\.stageTrigger), allowDoubleTap: true)
            TriggerPicker(state: state, title: "快速切换", desc: "按住修饰键连按，松开就切过去", trigger: binding(\.quickSwitch), allowDoubleTap: false)
            TriggerPicker(state: state, title: "侧栏", desc: "打开后按数字直达，鼠标停在窗口上按 ⇧数字 编号", trigger: binding(\.shelfTrigger), allowDoubleTap: true)
            TriggerPicker(state: state, title: "场景切换", desc: "场景截图卡片，左右滑选、回车摆到鼠标所在的屏；再按一次 = 下一个", trigger: binding(\.sceneTrigger), allowDoubleTap: true)
            slotPicker
            ForEach(model.settings.conflicts(), id: \.self) { c in
                Label(c, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
            }
            ForEach(state.bindFailures, id: \.self) { c in
                Label("\(c) 已被别的 App 占用，换一个吧", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 12))
            }
            Text("不想记任何快捷键也行：鼠标碰屏幕边缘就能打开后台，菜单栏图标里也有所有功能。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    var tester: some View {
        let fresh = Date().timeIntervalSince(state.detectedAt) < 2.5
        return HStack(spacing: 10) {
            Image(systemName: fresh ? "checkmark.seal.fill" : "keyboard").font(.system(size: 18))
                .foregroundStyle(fresh ? .green : .secondary)
            if fresh, let k = state.detected {
                let used = [("总控", model.settings.hubTrigger), ("舞台模式", model.settings.stageTrigger), ("侧栏", model.settings.shelfTrigger), ("场景切换", model.settings.sceneTrigger)].first { $0.1 == .doubleTap(k) }
                Text("检测到「双击 \(k.symbol)」" + (used.map { " → 会打开\($0.0)" } ?? "（还没分配功能）"))
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("试试双击右边的 ⌥ 或 ⌘ —— 这里会显示检测结果").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(fresh ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08)))
        .animation(.easeOut(duration: 0.2), value: state.detectedAt)
    }

    var slotPicker: some View {
        let cur = model.settings.slotModifier
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("数字槽位").font(.system(size: 13, weight: .semibold))
                    Text("修饰键+1~9 直达钉住的窗口，+⇧ 钉住当前窗口").font(.system(size: 11)).foregroundStyle(.secondary)
                }.frame(width: 230, alignment: .leading)
                Picker("", selection: Binding(get: { cur }, set: { v in
                    model.settings.slotModifier = v
                    model.saveSettings()
                    state.bindFailures = TriggerCenter.shared.failures
                })) {
                    ForEach(SlotModifier.allCases, id: \.self) { m in Text(m == .off ? "不用" : "\(m.symbol) 1~9").tag(m) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            Text(cur.note).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 240)
        }
    }

    func binding(_ kp: WritableKeyPath<WeftSettings, Trigger>) -> Binding<Trigger> {
        Binding(get: { model.settings[keyPath: kp] }, set: { v in
            model.settings[keyPath: kp] = v
            model.saveSettings()
            state.bindFailures = TriggerCenter.shared.failures
        })
    }
}

struct TriggerPicker: View {
    @ObservedObject var state: SetupState
    let title: String
    let desc: String
    @Binding var trigger: Trigger
    let allowDoubleTap: Bool
    @State private var monitor: Any?

    static let tapChoices: [ModKey] = [.rightOption, .rightCommand, .leftOption, .leftControl, .rightShift]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text(trigger.display).font(.system(size: 12, weight: .bold, design: .rounded))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(trigger == .off ? Color.secondary.opacity(0.15) : Color.purple.opacity(0.2)))
            }
            HStack(spacing: 6) {
                if allowDoubleTap {
                    ForEach(Self.tapChoices, id: \.self) { k in
                        chip("双击 \(k.symbol)", selected: trigger == .doubleTap(k), help: k.note) { trigger = .doubleTap(k) }
                    }
                } else {
                    chip("⌥ Tab", selected: trigger == .combo(.optionTab), help: "推荐") { trigger = .combo(.optionTab) }
                }
                chip(state.recording == title ? "请按下组合键…（esc 取消）" : "录制组合键", selected: isCombo && !(trigger == .combo(.optionTab) && !allowDoubleTap),
                     help: "例如 ⌃⌥Space、F5") { record() }
                chip("不用", selected: trigger == .off, help: "") { trigger = .off }
            }
            if case .doubleTap(let k) = trigger { Text(k.note).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
    }

    var isCombo: Bool { if case .combo = trigger { return true }; return false }

    func chip(_ t: String, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Color.purple.opacity(0.85) : Color.secondary.opacity(0.12)))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain).help(help)
    }

    func record() {
        if monitor != nil { stop(); return }
        state.recording = title
        TriggerCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            if let c = TriggerCenter.combo(from: e) {
                trigger = .combo(c)
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        state.recording = nil
        state.bindFailures = TriggerCenter.shared.resume()
    }
}

// MARK: - AI

struct AIPane: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SetupState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("选一个 AI 模型").font(.system(size: 18, weight: .bold))
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("选填。不配 AI 也能用全部核心功能：舞台、搜索、⌥Tab、侧栏、习惯推荐、规则整理。以后随时在设置里加。")
                        .font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.10)))
                Text("AI 用于「整理桌面」里的场景和清理判断，以及「排布建议」。发给模型的只有 App 名和窗口标题；微信、QQ、飞书等聊天软件只发 App 名。习惯学习完全在本机，不需要 AI。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(AIProvider.all) { p in providerCard(p) }
            }
            if let p = AIProvider.find(state.providerID) { detail(p) }
        }
    }

    func providerCard(_ p: AIProvider) -> some View {
        let sel = state.providerID == p.id
        return Button { state.choose(p) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Spacer()
                    if p.id == "magpie" {
                        Circle().fill(state.magpieUp ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                            .help(state.magpieUp ? "Magpie 正在运行" : "没检测到 Magpie")
                    }
                }
                Text(p.note.isEmpty ? (p.needsKey ? "需要 API Key" : "无需 Key") : p.note)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 10).fill(sel ? Color.purple.opacity(0.22) : Color.secondary.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(sel ? Color.purple : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    func detail(_ p: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if p.id == "custom" || p.id == "ollama" || p.id == "magpie" {
                field("地址") { TextField("https://…/v1", text: $state.baseURL).textFieldStyle(.roundedBorder) }
            }
            if p.needsKey {
                field("API Key") {
                    HStack {
                        SecureField("sk-…", text: $state.apiKey).textFieldStyle(.roundedBorder)
                            .onSubmit { state.fetchModels() }
                        if let u = p.keyURL, let url = URL(string: u) { Link("获取 Key", destination: url).font(.system(size: 12)) }
                    }
                }
            }
            field("模型") {
                HStack {
                    if state.models.isEmpty {
                        TextField(p.suggested.first ?? "模型名", text: $state.modelID).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $state.modelID) {
                            ForEach(state.models) { m in Text(m.label == m.id ? m.id : "\(m.label)（\(m.id)）").tag(m.id) }
                        }.labelsHidden()
                    }
                    Button { state.fetchModels() } label: {
                        if state.loadingModels { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.help("拉取模型列表")
                }
            }
            HStack {
                Button { state.test() } label: { Label("测试连接", systemImage: "bolt.horizontal") }
                    .disabled(state.modelID.isEmpty || state.testing || (p.needsKey && state.apiKey.isEmpty))
                if state.testing { ProgressView().controlSize(.small) }
                if let r = state.testResult {
                    Text(r).font(.system(size: 12)).foregroundStyle(r.hasPrefix("✓") ? .green : .orange).lineLimit(2)
                }
                Spacer()
                if !state.wizard {
                    Button("保存") {
                        model.aiConfig = state.draft
                        model.aiConfig.save()
                        model.refreshModels()
                        Toast.show("AI 模型：\(state.modelID)")
                    }.buttonStyle(.borderedProminent).tint(.purple).disabled(state.modelID.isEmpty)
                }
            }
            Text("API Key 保存在钥匙串里，不会写进配置文件。").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
    }

    func field<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label).font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
            c()
        }
    }
}

// MARK: - 舞台与侧栏

struct StagePane: View {
    @ObservedObject var model: AppModel
    var tryShelf: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("舞台模式").font(.system(size: 18, weight: .bold))
            HStack(spacing: 14) {
                ForEach(StageLayout.allCases, id: \.self) { l in
                    VStack(spacing: 6) {
                        LayoutIcon(spec: StageSpec(l), selected: true, size: CGSize(width: 66, height: 42))
                        Text(l.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Text("开启后每块屏幕只留 1~3 个窗口。用 ⌥Tab、侧栏、⌘Tab 或点 Dock 切到别的窗口，它就替换当前位置；◧ ◨ 可以直接放主位 / 副位。退出时后台窗口全部回到原位。")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("切到的窗口自动上台（⌘Tab、点 Dock、点通知也算）", isOn: bind(\.stageAutoPromote))
            Toggle("用毛玻璃盖住桌面（更干净，也防止误点桌面把窗口推开）", isOn: bind(\.stageCurtain))
            Toggle("⌃← / ⌃→ 和四指左右滑切换场景（像切系统桌面，带截图卡片）", isOn: bind(\.sceneSwipe))
            Text("舞台模式下 Weft 接管这两个手势；没开舞台时还是系统的切桌面。系统的四指滑会同时轻弹一下，不想看到可以在 系统设置 › 触控板 › 更多手势 里把「在全屏幕应用程序之间轻扫」改成三指或关掉。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("窗口间隙")
                Slider(value: bind(\.stageGap), in: 0...24, step: 2).frame(width: 200)
                Text("\(Int(model.settings.stageGap)) pt").monospacedDigit().foregroundStyle(.secondary)
            }
            Divider()
            Text("边缘后台").font(.system(size: 18, weight: .bold))
            HStack {
                Picker("鼠标碰到", selection: bind(\.shelfEdge)) {
                    Text("左边缘").tag(ShelfEdge.left)
                    Text("右边缘").tag(ShelfEdge.right)
                    Text("关闭").tag(ShelfEdge.off)
                }.pickerStyle(.segmented).frame(width: 300)
                Button("试一下", action: tryShelf).disabled(model.settings.shelfEdge == .off)
            }
            HStack {
                Text("停留多久弹出")
                Slider(value: bind(\.shelfDelay), in: 0.05...0.8, step: 0.05).frame(width: 200)
                Text(String(format: "%.2f 秒", model.settings.shelfDelay)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    func bind<T>(_ kp: WritableKeyPath<WeftSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: kp] }, set: { model.settings[keyPath: kp] = $0; model.saveSettings() })
    }
}

// MARK: - 记忆

struct MemoryPane: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var editing: String?
    @State private var editText = ""

    var body: some View {
        let _ = model.memoryRevision
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Weft 记得你怎么工作").font(.system(size: 18, weight: .bold))
                Text("几点用什么、哪几个窗口常摆在一起，都在本机统计。配了 AI 后，每天会把这些统计复盘成几句话，整理桌面、排布建议都会先读它们。你可以改、删，也可以自己写一句规则（AI 会优先遵守你写的）。")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("记住我的习惯", isOn: Binding(get: { model.memory.enabled }, set: { model.memory.enabled = $0; model.memoryRevision += 1 }))
            HStack {
                Text("记忆笔记").font(.system(size: 13, weight: .bold))
                Spacer()
                if model.digesting { ProgressView().controlSize(.small) }
                Button(model.memory.db.lastDigest == nil ? "让 AI 复盘一次" : "重新复盘") { model.digestMemory() }
                    .disabled(model.digesting || !model.aiConfig.isConfigured)
                    .help(model.aiConfig.isConfigured ? "把本机统计写成几句习惯笔记（你写的不会被覆盖）" : "先在「AI 模型」里选一个模型")
            }
            if model.memory.notes.isEmpty {
                Text(model.aiConfig.isConfigured ? "还没有笔记。用一段时间后会自动复盘，也可以现在点「让 AI 复盘一次」。" : "还没有笔记。可以自己写，或者配一个 AI 模型让它帮你总结。")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(model.memory.notes) { n in
                HStack(spacing: 8) {
                    Text(n.source == .user ? "✍️" : "🧠").font(.system(size: 13))
                    if editing == n.id {
                        TextField("", text: $editText).textFieldStyle(.roundedBorder)
                            .onSubmit { model.memory.update(n.id, text: editText); editing = nil; model.memoryRevision += 1 }
                        Button("好") { model.memory.update(n.id, text: editText); editing = nil; model.memoryRevision += 1 }
                    } else {
                        Text(n.text).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button { editing = n.id; editText = n.text } label: { Image(systemName: "pencil") }.buttonStyle(.borderless)
                        Button { model.memory.remove(n.id); model.memoryRevision += 1 } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                .padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
            }
            HStack {
                TextField("自己写一条，如「微信永远放笔记本右边」「写代码时不要放聊天」", text: $draft).textFieldStyle(.roundedBorder)
                    .onSubmit { model.memory.add(draft); draft = ""; model.memoryRevision += 1 }
                Button("记下") { model.memory.add(draft); draft = ""; model.memoryRevision += 1 }.disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            let ps = model.memory.patterns(minCount: 2)
            VStack(alignment: .leading, spacing: 6) {
                Text("常见摆法（本机统计）").font(.system(size: 13, weight: .bold))
                if ps.isEmpty {
                    Text("舞台上同一组窗口摆满 3 分钟会记一笔；同一种摆法在两天里出现过，就会出现在这里，侧栏也会在合适的时间提醒你。")
                        .font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(ps.prefix(6).enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 8) {
                        Text("\(p.count) 次 · \(p.typicalHour) 点左右").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                        Text(p.sample.parts.flatMap(\.members).map { m in m.title.isEmpty ? m.bundleID : String(m.title.prefix(18)) }.joined(separator: " + "))
                            .font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if p.sceneID == nil { Button("存成场景") { model.savePattern(p) }.controlSize(.small) }
                    }
                }
            }
            HStack {
                Spacer()
                Button("清空全部记忆", role: .destructive) { model.memory.clearAll(); model.memoryRevision += 1 }
            }
            Text("记忆存在本机 ~/Library/Application Support/Weft/memory.json。发给 AI 复盘的只有 App 名、窗口标题和使用时长；聊天软件只发 App 名。")
                .font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 完成

struct DonePane: View {
    @ObservedObject var model: AppModel
    var tryHub: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("好了，就这些").font(.system(size: 22, weight: .heavy, design: .rounded))
            row(model.settings.hubTrigger.display, "打开总控", "搜索拼音直达、按事情分组、排布建议")
            row(model.settings.stageTrigger.display, "舞台模式 开 / 关", "只留现在要用的窗口")
            row(model.settings.quickSwitch.display, "快速切换", "按住连按，松开即切")
            row(model.settings.shelfTrigger.display, "侧栏", "按数字直达，⇧数字 编号")
            row(model.settings.sceneTrigger.display, "场景切换", "截图卡片左右滑，每块屏各自换场景")
            if model.settings.sceneSwipe { row("⌃← →  四指滑", "切场景", "像切系统桌面：按住 ⌃ 连按 / 滑动选，松开就摆") }
            row(model.settings.shelfEdge == .off ? "已关闭" : "鼠标碰\(model.settings.shelfEdge == .left ? "左" : "右")边缘", "后台", "所有窗口，一点就上台")
            row(model.aiConfig.isConfigured ? model.aiConfig.providerName : "未配置", "AI", model.aiConfig.isConfigured ? model.aiConfig.model : "随时可以在设置里加")
            Button("试一下总控", action: tryHub)
            Text("以后改设置：菜单栏 Weft 图标 → 设置，或者在侧栏底部点齿轮。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    func row(_ key: String, _ title: String, _ desc: String) -> some View {
        HStack(spacing: 12) {
            Text(key).font(.system(size: 13, weight: .bold, design: .rounded)).frame(width: 140, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5).background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.15)))
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(desc).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 窗口

@MainActor
final class SetupController {
    let model: AppModel
    let state = SetupState()
    let perms = PermissionState()
    private var window: NSWindow?
    var tryHub: () -> Void = {}
    var tryShelf: () -> Void = {}

    init(model: AppModel) { self.model = model }

    func show(wizard: Bool, page: SetupPage? = nil) {
        state.wizard = wizard
        state.page = page ?? (wizard ? .welcome : .keys)
        state.loadAI(model.aiConfig)
        state.bindFailures = TriggerCenter.shared.failures
        TriggerCenter.shared.taps.onAnyDoubleTap = { [weak self] k in
            self?.state.detected = k
            self?.state.detectedAt = Date()
        }
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SetupView(
                model: model, state: state, perms: perms,
                finish: { [weak self] in self?.finish() },
                tryHub: { [weak self] in self?.window?.orderOut(nil); DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.tryHub() } },
                tryShelf: { [weak self] in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self?.tryShelf() } },
                relaunch: { Self.relaunch() }))
            w.setContentSize(NSSize(width: 720, height: 640))
            w.center()
            window = w
        }
        window?.title = wizard ? "欢迎使用 Weft" : "Weft 设置"
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        model.settings.setupDone = true
        model.saveSettings()
        window?.orderOut(nil)
        Toast.show("Weft 已就绪 · \(model.settings.hubTrigger.display) 打开总控", seconds: 3)
    }

    static func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}
