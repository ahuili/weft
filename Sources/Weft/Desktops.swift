import AppKit
import ApplicationServices
import Carbon
import WeftCore

// MARK: - 删桌面
//
// macOS 没有公开的「删除桌面」接口。和你手动操作一样：打开调度中心，在顶部的桌面条上点每个桌面的「×」。
// 这里通过辅助功能找到调度中心里的桌面按钮，执行它的「移除桌面」动作。
// 删掉一个有窗口的桌面时，系统会把上面的窗口挪到别的桌面，不会关掉任何窗口。

enum MissionControl {
    private static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) ?? [] }

    private static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static var dock: AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier else { return nil }
        return AXUIElementCreateApplication(pid)
    }

    /// 调度中心（四指上滑 / F3）是不是正开着：开着时程序坞的辅助功能树顶层会多出一个标识为 "mc" 的组
    static var isShowing: Bool {
        guard let dock else { return false }
        return children(dock).contains { (attr($0, "AXIdentifier") as String?) == "mc" }
    }

    /// 调试：程序坞顶层元素
    static func dockTop() -> String {
        guard let dock else { return "no dock" }
        return children(dock).map { "\(attr($0, kAXRoleAttribute) as String? ?? "?")#\(attr($0, "AXIdentifier") as String? ?? "-")" }.joined(separator: ",")
    }

    static func open() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
    }

    static func close() {
        // 再按一次 Esc 退出调度中心
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Escape), keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// 调度中心里每块屏的桌面按钮（顺序 = 桌面 1、2、3…）
    static func spaceLists() -> [[AXUIElement]] {
        guard let dock else { return [] }
        var out: [[AXUIElement]] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 10 else { return }
            let ident: String? = attr(e, "AXIdentifier")
            if ident == "mc.spaces.list" {
                out.append(children(e).filter { (attr($0, kAXRoleAttribute) as String?) == (kAXButtonRole as String) })
                return
            }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(dock, 0)
        return out
    }

    /// 调试：把调度中心打开时 Dock 的辅助功能树写下来
    @MainActor static func probe(to path: String) {
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            var out = ""
            func walk(_ e: AXUIElement, _ depth: Int) {
                guard depth < 9 else { return }
                let role: String = attr(e, kAXRoleAttribute) ?? "?"
                let ident: String = attr(e, "AXIdentifier") ?? ""
                let title: String = attr(e, kAXTitleAttribute) ?? attr(e, kAXDescriptionAttribute) ?? ""
                out += String(repeating: "  ", count: depth) + "\(role) id=\(ident) \"\(title)\" actions=\(actions(e))\n"
                for c in children(e) { walk(c, depth + 1) }
            }
            if let d = dock { walk(d, 0) }
            out += "lists=\(spaceLists().map(\.count))\n"
            try? out.write(toFile: path, atomically: true, encoding: .utf8)
            close()
        }
    }

    /// 删掉指定的桌面。remove：每块屏要删的桌面序号（从 1 开始，和桌面地图一致），按屏幕顺序对应调度中心里的桌面条。
    /// 完成后回调实际删掉的个数
    @MainActor static func removeDesktops(_ remove: [[Int]], done: @escaping (Int) -> Void) {
        open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            let lists = spaceLists()
            var removed = 0
            for (di, idxs) in remove.enumerated() where di < lists.count {
                let buttons = lists[di]
                // 从后往前删，前面的序号不受影响
                for i in idxs.sorted(by: >) where i >= 1 && i <= buttons.count {
                    let b = buttons[i - 1]
                    let acts = actions(b)
                    guard let act = acts.first(where: { $0 == "AXRemoveDesktop" }) ?? acts.first(where: { $0.lowercased().contains("remove") }) else { continue }
                    if AXUIElementPerformAction(b, act as CFString) == .success { removed += 1 }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                close()
                done(removed)
            }
        }
    }
}
