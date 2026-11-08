import CoreGraphics
import Foundation
import WeftCore

/// 自然语言 → 工具调用 → 窗口操作。
/// AI 只能调用白名单工具；执行前由调用方拍快照，所有操作可撤销。
public final class WindowAgent {
    public let client: ChatClient
    public let actions: WindowActions
    public let engine: LayoutEngine?
    public var maxSteps = 8
    public var onEvent: (String) -> Void = { _ in }

    public init(config: AIConfig, actions: WindowActions, engine: LayoutEngine? = nil) {
        self.client = ChatClient(config: config)
        self.actions = actions
        self.engine = engine
    }

    // MARK: 工具定义

    static func fn(_ name: String, _ desc: String, _ props: [String: Any], _ required: [String]) -> [String: Any] {
        ["type": "function",
         "function": ["name": name, "description": desc,
                      "parameters": ["type": "object", "properties": props, "required": required]]]
    }

    static let regionEnum = Region.allCases.map(\.rawValue)

    public static let tools: [[String: Any]] = [
        fn("list_windows", "列出所有窗口及其所在屏幕，返回 JSON。", [:], []),
        fn("focus_window", "把某个窗口切到最前并聚焦。", ["id": ["type": "integer"]], ["id"]),
        fn("place_window", "把窗口放到某块屏幕的某个区域。",
           ["id": ["type": "integer"],
            "display": ["type": "string", "description": "屏幕 id（list_windows 中的 displays[].id）或 \"main\"；省略=窗口当前屏幕"],
            "region": ["type": "string", "enum": regionEnum]],
           ["id", "region"]),
        fn("tile_windows", "把多个窗口在同一块屏幕上平铺。",
           ["ids": ["type": "array", "items": ["type": "integer"]],
            "display": ["type": "string", "description": "屏幕 id 或 \"main\""],
            "arrangement": ["type": "string", "enum": ["columns", "rows", "grid"]]],
           ["ids"]),
        fn("minimize_windows", "最小化或恢复一组窗口。",
           ["ids": ["type": "array", "items": ["type": "integer"]],
            "minimized": ["type": "boolean"]],
           ["ids", "minimized"]),
        fn("save_layout", "把当前布局保存为这组显示器的默认布局。", [:], []),
        fn("restore_layout", "恢复这组显示器保存过的布局。", [:], []),
    ]

    // MARK: 上下文

    public func snapshotJSON() -> String {
        let p = actions.profile()
        let redact = Set(client.config.redactTitlesFor)
        let displays = p.displays.map { d -> [String: Any] in
            ["id": String(d.id), "name": d.name, "main": d.isMain, "builtin": d.isBuiltin,
             "size": "\(Int(d.frame.width))x\(Int(d.frame.height))"]
        }
        let wins = actions.windows().map { w -> [String: Any] in
            let d = p.display(uuid: w.displayUUID)
            var o: [String: Any] = [
                "id": Int(w.id), "app": w.appName,
                "title": redact.contains(w.bundleID) ? "(已隐藏)" : String(w.title.prefix(120)),
                "display": d.map { String($0.id) } ?? "?",
                "minimized": w.isMinimized,
                "controllable": w.axAvailable,
            ]
            if let d, w.axAvailable {
                let r = w.frame.relative(to: d.visible)
                o["pos"] = String(format: "x=%.2f y=%.2f w=%.2f h=%.2f", r.minX, r.minY, r.width, r.height)
            }
            return o
        }
        let obj: [String: Any] = ["displays": displays, "windows": wins]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static let systemPrompt = """
    你是 Weft，macOS 窗口管理助手。用户用自然语言描述想要的窗口布局或操作，你通过调用工具完成。
    规则：
    - 只操作 controllable=true 的窗口；按 app 名和标题判断用户指的是哪个窗口，拿不准时选最可能的，并在最后说明。
    - pos 是窗口在所在屏幕可用区域中的相对位置（0~1）。
    - 尽量用最少的工具调用一次完成；多个窗口并排优先用 tile_windows。
    - 不要关闭窗口，不要做用户没要求的事。
    - 完成后用一句简短中文告诉用户做了什么。
    """

    // MARK: 执行循环

    /// 返回模型的最终说明
    public func run(_ instruction: String) async throws -> String {
        var messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt],
            ["role": "user", "content": "当前窗口与屏幕：\n\(snapshotJSON())\n\n指令：\(instruction)"],
        ]
        for _ in 0..<maxSteps {
            let reply = try await client.complete(messages: messages, tools: Self.tools)
            messages.append(reply.rawMessage)
            if reply.toolCalls.isEmpty {
                return reply.content?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "完成"
            }
            for call in reply.toolCalls {
                let result = execute(name: call.name, arguments: call.arguments)
                onEvent("→ \(call.name) \(call.arguments) ⇒ \(result.prefix(80))")
                messages.append(["role": "tool", "tool_call_id": call.id, "content": result])
            }
        }
        return "已达到最大步数，部分操作可能未完成"
    }

    // MARK: 工具实现

    func display(_ ref: Any?, fallbackFor windowID: UInt32? = nil) -> DisplayInfo? {
        let p = actions.profile()
        if let s = ref as? String ?? (ref as? Int).map(String.init) {
            if s == "main" { return p.main }
            if let d = p.displays.first(where: { String($0.id) == s || $0.name == s }) { return d }
        }
        if let id = windowID, let w = actions.windows().first(where: { $0.id == id }) {
            return p.display(uuid: w.displayUUID) ?? p.main
        }
        return p.main
    }

    static func ids(_ v: Any?) -> [UInt32] {
        (v as? [Any] ?? []).compactMap { ($0 as? Int).map(UInt32.init) ?? ($0 as? String).flatMap { UInt32($0) } }
    }

    static func id(_ v: Any?) -> UInt32? {
        (v as? Int).map(UInt32.init) ?? (v as? String).flatMap { UInt32($0) }
    }

    public func execute(name: String, arguments: String) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) as? [String: Any] ?? [:]
        switch name {
        case "list_windows":
            return snapshotJSON()
        case "focus_window":
            guard let id = Self.id(args["id"]) else { return "error: 缺少 id" }
            return actions.focus(id) ? "ok" : "error: 找不到窗口 \(id)"
        case "place_window":
            guard let id = Self.id(args["id"]),
                  let region = Region(rawValue: args["region"] as? String ?? "") else { return "error: 参数无效" }
            guard let d = display(args["display"], fallbackFor: id) else { return "error: 找不到屏幕" }
            actions.setMinimized(id, false)
            return actions.setFrame(id, region.rel.absolute(in: d.visible)) ? "ok" : "error: 窗口 \(id) 不可操作"
        case "tile_windows":
            let ids = Self.ids(args["ids"])
            guard !ids.isEmpty, let d = display(args["display"], fallbackFor: ids.first) else { return "error: 参数无效" }
            let rects = Region.tile(count: ids.count, arrangement: args["arrangement"] as? String ?? "columns")
            var failed: [UInt32] = []
            for (id, r) in zip(ids, rects) {
                actions.setMinimized(id, false)
                if !actions.setFrame(id, r.absolute(in: d.visible)) { failed.append(id) }
            }
            return failed.isEmpty ? "ok" : "部分失败：\(failed)"
        case "minimize_windows":
            let ids = Self.ids(args["ids"])
            let m = args["minimized"] as? Bool ?? true
            let ok = ids.filter { actions.setMinimized($0, m) }
            return "ok: \(ok.count)/\(ids.count)"
        case "save_layout":
            guard let e = engine else { return "error: 不可用" }
            return "ok: 保存 \(e.saveManual().windows.count) 个窗口"
        case "restore_layout":
            guard let e = engine else { return "error: 不可用" }
            return "ok: 调整 \(e.restore(label: "AI 恢复布局")) 个窗口"
        default:
            return "error: 未知工具 \(name)"
        }
    }
}
