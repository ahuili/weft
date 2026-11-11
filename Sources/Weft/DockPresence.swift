import AppKit

/// Weft 平时只在菜单栏，没有 Dock 图标、⌘Tab 里也没有。可设置、场景工作台是正经窗口：
/// 你一切场景、或者点了别的窗口，它就被盖到下面，又没有地方点回来。
/// 所以这两个窗口开着（含最小化）时，Weft 出现在 Dock 和 ⌘Tab 里；点 Dock 图标就回到它们；都关了再退回菜单栏。
@MainActor
enum DockPresence {
    private static var installed = false

    /// Weft 自己的正经窗口（设置、场景工作台），不算各种浮层面板
    static var docWindows: [NSWindow] {
        NSApp.windows.filter { !($0 is NSPanel) && $0.styleMask.contains(.titled) && ($0.isVisible || $0.isMiniaturized) }
    }

    static func install() {
        guard !installed else { return }
        installed = true
        let nc = NotificationCenter.default
        for n in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                  NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { refresh() } }
            }
        }
        // orderOut 没有通知：兜底每两秒看一次
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { refresh() } }
    }

    static func refresh() {
        let want: NSApplication.ActivationPolicy = docWindows.isEmpty ? .accessory : .regular
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        // 菜单只在有正经窗口时挂上：平时总控、切换器这些浮层里按 ⌘Q 不会把 Weft 退掉
        NSApp.mainMenu = want == .regular ? menu : nil
    }

    /// 点了 Dock 里的 Weft：把设置 / 场景工作台叫到最前面
    static func reopen() {
        for w in docWindows {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 出现在 Dock 时顶上的菜单栏；顺便让输入框里的 ⌘C ⌘V ⌘Z ⌘A 能用
    private static let menu: NSMenu = {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach { m.addItem($0) }
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ a: Selector, _ k: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k)
            i.keyEquivalentModifierMask = mods
            return i
        }
        sub("Weft", [item("隐藏 Weft", #selector(NSApplication.hide(_:)), "h"), .separator(),
                     item("退出 Weft", #selector(NSApplication.terminate(_:)), "q")])
        sub("编辑", [item("撤销", Selector(("undo:")), "z"), item("重做", Selector(("redo:")), "z", [.command, .shift]), .separator(),
                     item("剪切", #selector(NSText.cut(_:)), "x"), item("拷贝", #selector(NSText.copy(_:)), "c"),
                     item("粘贴", #selector(NSText.paste(_:)), "v"), item("全选", #selector(NSText.selectAll(_:)), "a")])
        sub("窗口", [item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
                     item("关闭", #selector(NSWindow.performClose(_:)), "w")])
        return main
    }()
}
