import Foundation
import WeftAI
import WeftCore

/// weft list | displays | save | restore | focus <查询> | models | ai "<指令>" [--model id]
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        let system = SystemWindows()
        let cmd = args.first ?? "help"
        if ["list", "save", "restore", "focus", "ai"].contains(cmd) && !Permissions.accessibility {
            fputs("⚠️ 当前进程没有辅助功能权限，只能看到部分窗口信息。请在 系统设置 → 隐私与安全性 → 辅助功能 中授权运行它的终端。\n", stderr)
        }
        switch cmd {
        case "list":
            let p = system.profile()
            for w in system.windows() {
                let d = p.display(uuid: w.displayUUID)?.name ?? "?"
                let flags = (w.isMinimized ? " [最小化]" : "") + (w.axAvailable ? "" : " [其他桌面]")
                print(String(format: "%-8u %-16@ %-14@ %@%@", w.id, w.appName as NSString,
                             d as NSString, w.title as NSString, flags as NSString))
            }
        case "doctor":
            // 用 open -a Weft --args doctor <输出文件> 启动，可以看到 Weft 自己的权限状态
            var out = "ax=\(Permissions.accessibility) screen=\(Permissions.screenCapture)\n"
            out += "bundle=\(Bundle.main.bundlePath) id=\(Bundle.main.bundleIdentifier ?? "-")\n"
            out += "pid=\(ProcessInfo.processInfo.processIdentifier) ppid=\(getppid())\n"
            if args.count > 1 { try? out.write(toFile: args[1], atomically: true, encoding: .utf8) } else { print(out) }
        case "ctl":
            // 调试：给正在运行的 Weft 发指令，如 weft ctl stage-on / layout split 1 / dump /tmp/x.txt
            DistributedNotificationCenter.default().postNotificationName(
                .init("local.weft.ctl"), object: args.dropFirst().joined(separator: " "), userInfo: nil, deliverImmediately: true)
            Thread.sleep(forTimeInterval: 0.3)
        case "displays":
            let p = system.profile()
            print("fingerprint: \(p.fingerprint)")
            for d in p.displays {
                print("\(d.id)\t\(d.name)\(d.isMain ? " (主屏)" : "")\(d.isBuiltin ? " (内建)" : "")\t\(d.frame)\t可用 \(d.visible)")
            }
        case "save":
            let e = LayoutEngine(actions: system)
            _ = e.saveManual()
        case "restore":
            let e = LayoutEngine(actions: system)
            _ = e.restore()
        case "focus":
            let q = args.dropFirst().joined(separator: " ")
            guard let w = FuzzyMatcher.rank(system.windows(), query: q).first else { print("没找到：\(q)"); return 1 }
            print("→ \(w.appName) · \(w.title)")
            system.focus(w.id)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        case "models":
            let cfg = AIConfig.load()
            return wait {
                let ms = try await ModelDiscovery.listModels(baseURL: cfg.baseURL, apiKey: cfg.apiKey)
                for m in ms { print("\(m.id == cfg.model ? "*" : " ") \(m.id)\t\(m.label)\(m.supportsTools ? "" : "\t(不支持工具调用)")") }
            }
        case "ai":
            var rest = Array(args.dropFirst())
            var cfg = AIConfig.load()
            if let i = rest.firstIndex(of: "--model"), i + 1 < rest.count {
                cfg.model = rest[i + 1]
                rest.removeSubrange(i...(i + 1))
            }
            let text = rest.joined(separator: " ")
            guard !text.isEmpty else { print("用法：weft ai \"把 Chrome 放左边\""); return 1 }
            let engine = LayoutEngine(actions: system)
            let agent = WindowAgent(config: cfg, actions: system, engine: engine)
            agent.onEvent = { print($0) }
            return wait { print(try await agent.run(text)) }
        default:
            print("""
            Weft —— 以「事情」为中心的窗口工作台
            无参数运行：启动菜单栏 App
              list               列出所有窗口
              displays           显示器信息与指纹
              save / restore     保存 / 恢复当前显示器组合的布局
              focus <查询>       模糊搜索并切到窗口（支持拼音）
              models             列出可用 AI 模型（默认来自 Magpie）
              ai "<指令>" [--model id]   用自然语言整理窗口
            """)
        }
        return 0
    }

    private static func wait(_ body: @escaping () async throws -> Void) -> Int32 {
        final class Box: @unchecked Sendable { var code: Int32 = 0 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            do { try await body() } catch { fputs("错误：\(error)\n", stderr); box.code = 1 }
            done.signal()
        }
        // 主线程要跑 RunLoop，AX / NSWorkspace 回调才能工作
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return box.code
    }
}
