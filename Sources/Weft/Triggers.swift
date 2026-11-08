import AppKit
import Carbon
import WeftCore

/// 检测「双击某个修饰键」（区分左右）：两次单独按下并快速松开，中间没有按别的键。
final class ModifierTaps {
    var handlers: [UInt16: () -> Void] = [:]
    /// 任何修饰键被双击都会回调（引导页的实时检测用）
    var onAnyDoubleTap: ((ModKey) -> Void)?
    private var monitors: [Any] = []
    private var downKey: UInt16 = 0
    private var downAt: TimeInterval = 0
    private var lastKey: UInt16 = 0
    private var lastTapAt: TimeInterval = 0
    private var clean = false

    func start() {
        guard monitors.isEmpty else { return }
        let handler: (NSEvent) -> Void = { [weak self] e in self?.handle(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { handler($0); return $0 }) { monitors.append(l) }
    }

    /// 组合键触发时调用，避免把组合键误判为单击
    func reset() { clean = false; lastTapAt = 0 }

    static func category(_ k: ModKey) -> NSEvent.ModifierFlags {
        switch k {
        case .leftOption, .rightOption: return .option
        case .leftCommand, .rightCommand: return .command
        case .leftControl, .rightControl: return .control
        case .leftShift, .rightShift: return .shift
        }
    }

    private func handle(_ e: NSEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if e.type == .keyDown { reset(); return }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        guard let key = ModKey.allCases.first(where: { $0.keyCode == e.keyCode }) else { reset(); return }
        let cat = Self.category(key)
        if flags == cat {
            downKey = e.keyCode
            downAt = now
            clean = true
        } else if flags.isEmpty {
            if clean && downKey == e.keyCode && now - downAt < 0.3 {
                if lastKey == e.keyCode && now - lastTapAt < 0.4 {
                    lastTapAt = 0
                    DispatchQueue.main.async {
                        self.onAnyDoubleTap?(key)
                        self.handlers[e.keyCode]?()
                    }
                } else {
                    lastKey = e.keyCode
                    lastTapAt = now
                }
            }
            clean = false
        } else {
            reset()
        }
    }
}

/// 把设置里的触发方式绑定到功能上
@MainActor
final class TriggerCenter {
    static let shared = TriggerCenter()
    let taps = ModifierTaps()
    private var bindings: [(Trigger, () -> Void)] = []
    private var quick: ((Int, NSEvent.ModifierFlags) -> Void)?
    private var quickTrigger: Trigger = .off
    private(set) var failures: [String] = []
    private var slotMod: SlotModifier = .off
    private var onSlot: ((Int) -> Void)?
    private var onPin: ((Int) -> Void)?

    /// 数字槽位：修饰键+1~9 跳转，修饰键+⇧+1~9 钉住
    func applySlots(_ mod: SlotModifier, jump: @escaping (Int) -> Void, pin: @escaping (Int) -> Void) {
        slotMod = mod; onSlot = jump; onPin = pin
    }

    static let digitKeys = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    /// 返回注册失败（被别的 App 占用）的组合键
    @discardableResult
    func apply(hub: Trigger, stage: Trigger, quickSwitch: Trigger, shelf: Trigger = .off, scene: Trigger = .off,
               onHub: @escaping () -> Void, onStage: @escaping () -> Void, onShelf: @escaping () -> Void = {},
               onScene: @escaping () -> Void = {},
               onQuick: @escaping (Int, NSEvent.ModifierFlags) -> Void) -> [String] {
        bindings = [(hub, onHub), (stage, onStage), (shelf, onShelf), (scene, onScene)]
        quick = onQuick
        quickTrigger = quickSwitch
        return resume()
    }

    /// 录制快捷键时暂停，免得按下去直接触发了旧功能
    func suspend() {
        HotKeys.shared.unregisterAll()
        taps.handlers.removeAll()
    }

    @discardableResult
    func resume() -> [String] {
        suspend()
        taps.start()
        var fail: [String] = []
        for (t, action) in bindings {
            switch t {
            case .doubleTap(let k): taps.handlers[k.keyCode] = action
            case .combo(let c):
                if !HotKeys.shared.register(keyCode: Int(c.keyCode), modifiers: c.modifiers, { [weak self] in self?.taps.reset(); action() }) {
                    fail.append(c.display)
                }
            case .off: break
            }
        }
        if case .combo(let c) = quickTrigger, let quick {
            let hold = Self.flags(c.modifiers).subtracting(.shift)
            if !HotKeys.shared.register(keyCode: Int(c.keyCode), modifiers: c.modifiers, { [weak self] in self?.taps.reset(); quick(1, hold) }) {
                fail.append(c.display)
            }
            if c.modifiers & KeyCombo.shift == 0 {
                _ = HotKeys.shared.register(keyCode: Int(c.keyCode), modifiers: c.modifiers | KeyCombo.shift) { [weak self] in
                    self?.taps.reset(); quick(-1, hold)
                }
            }
        }
        if slotMod != .off, let jump = onSlot, let pin = onPin {
            var slotFail = false
            for (i, k) in Self.digitKeys.enumerated() {
                let n = i + 1
                if !HotKeys.shared.register(keyCode: k, modifiers: slotMod.carbon, { [weak self] in self?.taps.reset(); jump(n) }) { slotFail = true }
                if !HotKeys.shared.register(keyCode: k, modifiers: slotMod.carbon | KeyCombo.shift, { [weak self] in self?.taps.reset(); pin(n) }) { slotFail = true }
            }
            if slotFail { fail.append("\(slotMod.symbol)数字（部分）") }
        }
        failures = fail
        return fail
    }

    static func flags(_ carbon: UInt32) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & KeyCombo.cmd != 0 { f.insert(.command) }
        if carbon & KeyCombo.option != 0 { f.insert(.option) }
        if carbon & KeyCombo.control != 0 { f.insert(.control) }
        if carbon & KeyCombo.shift != 0 { f.insert(.shift) }
        return f
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if f.contains(.command) { c |= KeyCombo.cmd }
        if f.contains(.option) { c |= KeyCombo.option }
        if f.contains(.control) { c |= KeyCombo.control }
        if f.contains(.shift) { c |= KeyCombo.shift }
        return c
    }

    /// 把一次按键变成 KeyCombo；没有 ⌘/⌥/⌃ 且不是 F 键的不接受
    static func combo(from e: NSEvent) -> KeyCombo? {
        let f = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let fKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
        let isF = fKeys.contains(Int(e.keyCode))
        guard isF || !f.intersection([.command, .option, .control]).isEmpty else { return nil }
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return KeyCombo(keyCode: UInt32(e.keyCode), modifiers: carbon(f), display: s + " " + keyName(e))
    }

    static func keyName(_ e: NSEvent) -> String {
        let names: [Int: String] = [kVK_Space: "Space", kVK_Tab: "Tab", kVK_Return: "↩", kVK_Escape: "esc", kVK_Delete: "⌫",
                                    kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
                                    kVK_ANSI_Grave: "`", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
                                    kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        if let n = names[Int(e.keyCode)] { return n }
        return (e.charactersIgnoringModifiers ?? "?").uppercased()
    }
}
