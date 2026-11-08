import Foundation
import WeftCore

/// AI 整理桌面：把窗口分成几个「场景」——每个场景是一次要摆上屏幕的一小组窗口（每块屏最多 4 个，带版式）。
/// 以前的「分组」只是把窗口归类，分完屏幕上什么都不变；现在每个场景都能一键摆出来。
public struct ContextProposal: Equatable {
    public var name: String
    public var emoji: String
    public var windowIDs: [UInt32]
    public var reason: String
    /// 这个场景在每块屏上怎么摆
    public var scenes: [ArrangedScene] = []
}

public struct DeskAdvice: Equatable {
    public var summary: String
    public var proposals: [ContextProposal]
    /// 建议设成随手窗口的 App（AI 给的是 App 名字，界面层换成 bundleID）
    public var floatingApps: [String] = []
    public var floatingReason: String = ""
}

public final class Organizer {
    public let client: ChatClient
    public init(config: AIConfig) { client = ChatClient(config: config) }

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "propose_scenes",
            "description": "把窗口整理成几个可以一键摆上屏幕的场景。",
            "parameters": [
                "type": "object",
                "properties": [
                    "summary": ["type": "string", "description": "一句话说现在桌面的状况和你的整理思路，40 字以内；用户写了要求时说明你怎么照做的"],
                    "floating_apps": ["type": "array", "items": ["type": "string"],
                                      "description": "建议设成「随手窗口」的 App 名（和 windows 里的 app 字段一致）：随开随关、不该固定在场景里的，如访达、预览、系统设置、计算器。没有就给空数组"],
                    "floating_reason": ["type": "string", "description": "一句话说为什么这些 App 适合随手"],
                    "scenes": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "2~8 个字，具体到事情，如「Weft 开发」「澜起财报」「回消息」"],
                                "emoji": ["type": "string"],
                                "reason": ["type": "string", "description": "一句话：为什么这几个窗口要一起看"],
                                "displays": [
                                    "type": "array",
                                    "description": "每块屏怎么摆；没合适窗口的屏可以不写",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "display": ["type": "integer"],
                                            "name": ["type": "string", "description": "场景跨两块屏时，这块屏这部分的短名（2~4 个字，如「聊天」「邮件」），会拆成独立场景"],
                                            "layout": ["type": "string", "enum": Arranger.layouts],
                                            "window_ids": ["type": "array", "items": ["type": "integer"], "description": "按格子顺序，第一个是主窗口；不超过版式的格子数"],
                                        ],
                                        "required": ["display", "layout", "window_ids"],
                                    ],
                                ],
                            ],
                            "required": ["name", "emoji", "displays"],
                        ],
                    ],
                ],
                "required": ["scenes"],
            ],
        ],
    ]

    static let systemPrompt = """
    你是 Weft 的桌面整理师。用户的 Mac 上窗口很乱：开了很多、散在好几个桌面上。请像整理书桌一样，把窗口整理成 3~8 个「场景」。
    场景 = 用户某个时刻要同时看着的一小组窗口，会被一键摆到屏幕上（其余窗口暂时退到后台，不会关闭）。
    Weft 的场景取代系统桌面：每块屏可以单独切换场景，自由组合（笔记本放「回消息」、大屏放「写代码」）。
    跨两块屏的场景会被拆成两个独立场景（各自的 name）+ 一个组合；只用一块屏就够的场景，只写一块屏。
    原则：
    - user_request 是用户这次亲口说的要求，最优先；但不要逐字硬凑：要求和「放不放得下、好不好用」冲突时，按好用的来，并在 reason 里说明。
    - 同一个窗口可以做成几个「变体」场景：比如 Claude 单独一个场景（专心写），再和微信组成一个场景（边聊边写）。用户提到「有时 A 单独、有时和 B 一起」时就这样做。
    - 同一个 App 有好几个窗口（比如浏览器开了好几个）：按窗口标题看在做什么，分到不同场景，不要一股脑塞进一个场景。
    - 窗口大小要合适：每个窗口有 width/height（现在的尺寸），min_width（实测最窄能压到多宽）。格子比 min_width 窄就别放进去。
      笔记本屏（宽 < 1800）：1 个主窗口 focus/full，最多 split 两个；聊天类（微信、Telegram、钉钉）可以窄，编辑器/浏览器/表格需要宽。大屏才用 triple / quad。
    - 随开随关的窗口（访达、预览、系统设置、计算器、下载、临时弹出的小工具）不要放进场景，列进 floating_apps：Weft 会让它们原样浮在上面，切场景也不藏。
    - existing_scenes 是用户已经有的场景：不要重复建一模一样的；可以建新的，或者用相同 name 改进已有的（会覆盖那个场景）。floating 里已经是随手的 App 不要再放进场景。
    - 场景要小而具体：每块屏 1~4 个窗口。不要把所有东西塞进一个大场景；宁可少分，也不要硬凑。
    - 按「在做的事」分，不按 App 分：一个项目的编辑器 + 终端 + 对应网页是一个场景；各种聊天软件可以是「回消息」场景。
    - co_usage（经常来回切换的窗口对）是最强的同场景信号；minutes（累计使用分钟）大的窗口更重要；last_used_days 很大的窗口多半不用放进场景。
    - 版式：focus 单窗居中、full 铺满、split 左右、main-stack 一主两辅、triple 三栏、quad 四宫格。笔记本屏（宽 < 1800）最多 split；大屏可以 main-stack / triple / quad。
    - 多块屏时：主屏放主要工作，另一块放参考资料或沟通。
    - 窗口可以出现在不同场景里（比如聊天窗口），但同一个场景里只出现一次。
    - desktop 字段表示窗口在其他桌面上；也可以放进场景（整理时会把桌面合并）。
    - user_memory 是用户的习惯记忆（有的是用户亲手写的），优先遵守。
    - 必须调用 propose_scenes。
    """

    public struct Input {
        public var windows: [WindowInfo]
        public var profile: DisplayProfile
        public var coUsage: [(UInt32, UInt32, Int)]
        public var minutes: [UInt32: Double]
        public var lastUsedDays: [UInt32: Double]
        public var desktops: [UInt32: (display: Int, desktop: Int)]
        public var redact: Set<String>
        /// 用户的习惯记忆（Weft 记忆笔记）
        public var memory: [String]
        /// 这次用户写的要求（可以空）
        public var request: String = ""
        /// 已有的场景：名字、属于哪块屏、里面的 App
        public var existing: [[String: Any]] = []
        /// 已经是随手窗口的 App 名
        public var floating: [String] = []
        /// 实测最窄宽度
        public var minWidth: [UInt32: Double] = [:]
        public init(windows: [WindowInfo], profile: DisplayProfile, coUsage: [(UInt32, UInt32, Int)], minutes: [UInt32: Double],
                    lastUsedDays: [UInt32: Double], desktops: [UInt32: (display: Int, desktop: Int)], redact: Set<String>, memory: [String] = []) {
            self.windows = windows; self.profile = profile; self.coUsage = coUsage; self.minutes = minutes
            self.lastUsedDays = lastUsedDays; self.desktops = desktops; self.redact = redact; self.memory = memory
        }
    }

    public func propose(_ input: Input) async throws -> DeskAdvice {
        let displays = input.profile.displays
        let dIndex = Dictionary(displays.enumerated().map { ($1.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let wins = input.windows.map { w -> [String: Any] in
            var o: [String: Any] = ["id": Int(w.id), "app": w.appName,
                                    "title": input.redact.contains(w.bundleID) ? "(隐藏)" : String(w.title.prefix(100))]
            if let i = w.displayUUID.flatMap({ dIndex[$0] }) { o["display"] = i }
            if !w.axAvailable, let d = input.desktops[w.id] { o["display"] = d.display; o["desktop"] = d.desktop }
            if let m = input.minutes[w.id], m >= 1 { o["minutes"] = Int(m) }
            if let d = input.lastUsedDays[w.id] { o["last_used_days"] = (d * 10).rounded() / 10 }
            if w.isMinimized { o["minimized"] = true }
            o["width"] = Int(w.frame.width); o["height"] = Int(w.frame.height)
            if let m = input.minWidth[w.id] { o["min_width"] = Int(m) }
            if w.fixedSize == true { o["fixed_size"] = true }
            return o
        }
        var payload: [String: Any] = [
            "displays": displays.enumerated().map { i, d in
                ["index": i, "name": d.isBuiltin ? "笔记本屏" : d.name, "width": Int(d.visible.width),
                 "height": Int(d.visible.height), "main": d.isMain] as [String: Any]
            },
            "windows": wins,
            "co_usage": input.coUsage.prefix(30).map { ["a": Int($0.0), "b": Int($0.1), "times": $0.2] },
        ]
        if !input.memory.isEmpty { payload["user_memory"] = input.memory }
        let req = input.request.trimmingCharacters(in: .whitespacesAndNewlines)
        if !req.isEmpty { payload["user_request"] = req }
        if !input.existing.isEmpty { payload["existing_scenes"] = input.existing }
        if !input.floating.isEmpty { payload["floating"] = input.floating }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let reply = try await client.complete(
            messages: [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": json]],
            tools: [Self.tool], toolChoice: ["type": "function", "function": ["name": "propose_scenes"]], timeout: 180)
        var text = reply.toolCalls.first(where: { $0.name == "propose_scenes" })?.arguments
        if text == nil, let c = reply.content, let r = c.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) { text = String(c[r]) }
        guard let text, let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw AIError.badResponse("propose_scenes") }
        let apps = Set(input.windows.map(\.appName))
        return DeskAdvice(summary: (obj["summary"] as? String) ?? "",
                          proposals: Self.parse(obj["scenes"] as? [[String: Any]] ?? [], valid: Set(input.windows.map(\.id)),
                                                displayCount: displays.count),
                          floatingApps: ((obj["floating_apps"] as? [String]) ?? []).filter { apps.contains($0) && !input.floating.contains($0) },
                          floatingReason: (obj["floating_reason"] as? String) ?? "")
    }

    /// 校验：去掉不存在的窗口 / 屏幕；每个场景每块屏最多放满版式；没有窗口的场景丢掉；最多 6 个
    public static func parse(_ arr: [[String: Any]], valid: Set<UInt32>, displayCount: Int) -> [ContextProposal] {
        var seenNames = Set<String>()
        return arr.compactMap { s -> ContextProposal? in
            guard let name = s["name"] as? String, !name.isEmpty, !seenNames.contains(name) else { return nil }
            let option = Arranger.parse([["name": name, "scenes": s["displays"] ?? []]], valid: valid, displayCount: displayCount).first
            guard let option, !option.scenes.isEmpty else { return nil }
            seenNames.insert(name)
            var ids: [UInt32] = []
            for sc in option.scenes { for id in sc.windowIDs where !ids.contains(id) { ids.append(id) } }
            return ContextProposal(name: name, emoji: (s["emoji"] as? String) ?? "🗂️", windowIDs: ids,
                                   reason: (s["reason"] as? String) ?? "", scenes: option.scenes)
        }.prefix(8).map { $0 }
    }
}
