import Foundation
import WeftCore

/// AI 排布：看你开着的窗口、屏幕、习惯，给出 1~3 套「舞台」方案（每块屏放哪几个窗口、用什么版式）。
public struct ArrangedScene: Equatable {
    public var displayIndex: Int
    public var spec: StageSpec
    public var windowIDs: [UInt32]
    /// 这块屏这部分的名字（整理桌面时 AI 给的，可以没有）
    public var name: String? = nil
}

public struct ArrangementOption: Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var summary: String
    public var scenes: [ArrangedScene]
}

public struct ArrangeInput {
    public var windows: [WindowInfo]
    public var profile: DisplayProfile
    public var focused: UInt32?
    public var recent: [UInt32]
    public var coUsage: [(UInt32, UInt32, Int)]
    public var contexts: [(name: String, ids: [UInt32])]
    public var redact: Set<String>
    /// 用户的习惯记忆
    public var memory: [String] = []
    public init(windows: [WindowInfo], profile: DisplayProfile, focused: UInt32?, recent: [UInt32],
                coUsage: [(UInt32, UInt32, Int)], contexts: [(name: String, ids: [UInt32])], redact: Set<String>) {
        self.windows = windows; self.profile = profile; self.focused = focused; self.recent = recent
        self.coUsage = coUsage; self.contexts = contexts; self.redact = redact
    }
}

public final class Arranger {
    public let client: ChatClient
    public init(config: AIConfig) { client = ChatClient(config: config) }

    static let layouts = ["focus", "full", "split", "main-stack", "triple", "quad"]

    static let tool: [String: Any] = [
        "type": "function",
        "function": [
            "name": "propose_arrangements",
            "description": "给出 1~3 套窗口摆放方案。",
            "parameters": [
                "type": "object",
                "properties": [
                    "options": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "name": ["type": "string", "description": "4~8 个字，如「专注写代码」「边查边写」"],
                                "summary": ["type": "string", "description": "一句话说明为什么这么摆"],
                                "scenes": [
                                    "type": "array",
                                    "items": [
                                        "type": "object",
                                        "properties": [
                                            "display": ["type": "integer", "description": "屏幕序号"],
                                            "layout": ["type": "string", "enum": layouts],
                                            "ratio": ["type": "number", "description": "split/main-stack：主窗口宽度比例 0.5~0.7；triple：中间栏比例 0.34~0.5"],
                                            "main_on_right": ["type": "boolean"],
                                            "window_ids": ["type": "array", "items": ["type": "integer"], "description": "按槽位顺序，第一个是主窗口"],
                                        ],
                                        "required": ["display", "layout", "window_ids"],
                                    ],
                                ],
                            ],
                            "required": ["name", "scenes"],
                        ],
                    ],
                ],
                "required": ["options"],
            ],
        ],
    ]

    static let systemPrompt = """
    你是 Weft 的排布顾问。用户的 Mac 上开了很多窗口，你要为「接下来这段时间」设计 1~3 套干净的摆放方案：
    每块屏幕只放 1~3 个最该同时看到的窗口，其余窗口暂时退到后台（不会关闭，随时能叫回来）。
    版式：
    - focus：单窗居中、两边留白，适合写作 / 阅读 / 超宽屏
    - full：单窗铺满
    - split：左右两栏，ratio = 主窗口宽度比例（0.5~0.7）
    - main-stack：左边主窗口 + 右边上下两个辅助窗口，ratio = 主窗口宽度比例
    - triple：三栏，中间是主窗口，适合宽屏
    原则：
    - 以当前窗口（focused）和最近在用的窗口（recent，越靠前越近）为核心；co_usage 是经常来回切换的窗口对，适合同屏并排。
    - window_ids 第一个是主窗口（编辑器、文档、正在读的网页）；参考资料、终端、聊天放辅位。
    - 笔记本屏（宽度 < 1800）最多两栏；外接大屏可以三栏或一主两辅。
    - 多块屏幕时：主屏放主要工作，另一块放参考资料或沟通。没有合适窗口的屏幕可以不放。
    - 每套方案侧重点要明显不同（如「专注写代码」「边查资料边写」「处理消息」）。
    - user_memory 是用户的习惯记忆（有的是用户亲手写的），优先遵守。
    - 必须调用 propose_arrangements。
    """

    public func propose(_ input: ArrangeInput) async throws -> [ArrangementOption] {
        let displays = input.profile.displays
        let dIndex = Dictionary(displays.enumerated().map { ($1.uuid, $0) }, uniquingKeysWith: { a, _ in a })
        let wins = input.windows.map { w -> [String: Any] in
            var o: [String: Any] = ["id": Int(w.id), "app": w.appName,
                                    "title": input.redact.contains(w.bundleID) ? "(隐藏)" : String(w.title.prefix(100))]
            if let i = w.displayUUID.flatMap({ dIndex[$0] }) { o["display"] = i }
            if w.isMinimized { o["minimized"] = true }
            return o
        }
        let payload: [String: Any] = [
            "displays": displays.enumerated().map { i, d in
                ["index": i, "name": d.isBuiltin ? "笔记本屏" : d.name, "width": Int(d.visible.width),
                 "height": Int(d.visible.height), "main": d.isMain] as [String: Any]
            },
            "windows": wins,
            "focused": input.focused.map { Int($0) } as Any,
            "recent": input.recent.prefix(10).map { Int($0) },
            "co_usage": input.coUsage.prefix(20).map { ["a": Int($0.0), "b": Int($0.1), "times": $0.2] },
            "contexts": input.contexts.map { ["name": $0.name, "window_ids": $0.ids.map { Int($0) }] as [String: Any] },
            "user_memory": input.memory,
        ]
        let json = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let reply = try await client.complete(
            messages: [["role": "system", "content": Self.systemPrompt], ["role": "user", "content": json]],
            tools: [Self.tool], toolChoice: ["type": "function", "function": ["name": "propose_arrangements"]], timeout: 180)
        var text = reply.toolCalls.first(where: { $0.name == "propose_arrangements" })?.arguments
        if text == nil, let c = reply.content, let r = c.range(of: #"\{[\s\S]*\}"#, options: .regularExpression) { text = String(c[r]) }
        guard let text, let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let arr = obj["options"] as? [[String: Any]] else { throw AIError.badResponse("propose_arrangements") }
        return Self.parse(arr, valid: Set(input.windows.map(\.id)), displayCount: displays.count)
    }

    /// 校验模型输出：去掉不存在的窗口 / 屏幕，截断超出版式的窗口
    public static func parse(_ arr: [[String: Any]], valid: Set<UInt32>, displayCount: Int) -> [ArrangementOption] {
        arr.prefix(3).compactMap { o in
            guard let name = o["name"] as? String else { return nil }
            var used = Set<UInt32>(), usedDisplays = Set<Int>()
            let scenes: [ArrangedScene] = (o["scenes"] as? [[String: Any]] ?? []).compactMap { s in
                let d = (s["display"] as? Int) ?? Int(s["display"] as? String ?? "") ?? 0
                guard d >= 0, d < displayCount, !usedDisplays.contains(d) else { return nil }
                let raw = (s["layout"] as? String) ?? "focus"
                let layout: StageLayout = raw == "main-stack" ? .mainStack : StageLayout(rawValue: raw) ?? .focus
                var spec = StageSpec(layout, mirrored: (s["main_on_right"] as? Bool) ?? false)
                if let r = (s["ratio"] as? Double) ?? (s["ratio"] as? Int).map(Double.init) {
                    let lo = layout == .triple ? 0.3 : 0.3, hi = layout == .triple ? 0.6 : 0.75
                    if layout != .focus && layout != .full { spec.ratio = min(hi, max(lo, r)) }
                }
                let ids = (s["window_ids"] as? [Any] ?? []).compactMap { v -> UInt32? in
                    let id = (v as? Int).map(UInt32.init) ?? (v as? String).flatMap { UInt32($0) }
                    guard let id, valid.contains(id), !used.contains(id) else { return nil }
                    used.insert(id)
                    return id
                }.prefix(layout.slots)
                guard !ids.isEmpty else { return nil }
                usedDisplays.insert(d)
                let part = (s["name"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : String($0.prefix(8)) }
                return ArrangedScene(displayIndex: d, spec: StageGeometry.effective(spec, filled: ids.count), windowIDs: Array(ids), name: part)
            }
            guard !scenes.isEmpty else { return nil }
            return ArrangementOption(name: name, summary: (o["summary"] as? String) ?? "", scenes: scenes)
        }
    }

    /// 不用 AI 的即时建议：按你的习惯，把当前窗口和最常一起用的窗口并排
    public static func habitPair(focused: WindowInfo?, windows: [WindowInfo], coUsage: [(UInt32, UInt32, Int)]) -> WindowInfo? {
        guard let f = focused else { return nil }
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let best = coUsage.filter { ($0.0 == f.id || $0.1 == f.id) && $0.2 >= 2 }.max { $0.2 < $1.2 }
        guard let best else { return nil }
        return byID[best.0 == f.id ? best.1 : best.0]
    }
}
