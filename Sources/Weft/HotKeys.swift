import Carbon
import Foundation

/// 基于 Carbon RegisterEventHotKey 的全局快捷键（无需辅助功能权限）
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var installed = false

    enum Mod {
        static let cmd = UInt32(cmdKey), opt = UInt32(optionKey), ctrl = UInt32(controlKey), shift = UInt32(shiftKey)
    }

    /// keyCode 用 kVK_* 常量
    @discardableResult
    func register(keyCode: Int, modifiers: UInt32, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x5746_5446), id: id) // 'WFTF'
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, hkID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKeys.shared.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
