import AppKit
import CoreGraphics
import Foundation

// MARK: - 像切系统桌面一样切场景
//
// Weft 接管以后实际上只有一个系统桌面，所以把切桌面的两个老习惯拿来切场景：
// - ⌃← / ⌃→：第一下只浮出卡片（停在这块屏现在的场景上），按住 ⌃ 再按方向键才挪；松开 ⌃ 摆出来。
//   没挪就松开 ⌃：卡片留着，变成普通的场景切换器（方向键 / Tab / 回车）
// - 四指左右滑：卡片跟着手指走，抬手摆出来
// 只在舞台模式下接管；没开舞台时原样交给系统。

/// ⌃← / ⌃→。要抢在系统「切换桌面」快捷键之前拿到按键，只能用事件截取（需要辅助功能权限，Weft 本来就有）
final class SceneKeys {
    /// 现在要不要接管（舞台开着、有场景）
    var enabled: () -> Bool = { false }
    /// 第一下：只浮出来
    var onOpen: () -> Void = {}
    /// 刚按下 ⌃
    var onPress: () -> Void = {}
    var onStep: (Int) -> Void = { _ in }
    /// 按着 ⌃ 时按 Tab：换目标屏
    var onTab: () -> Void = {}
    var onCommit: () -> Void = {}
    var onCancel: () -> Void = {}
    var log: (String) -> Void = { _ in }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// 正在「按住 ⌃ 选场景」
    fileprivate var holding = false

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: sceneKeysCallback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    func stop() {
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        if let t = tap { CGEvent.tapEnable(tap: t, enable: false) }
        tap = nil; source = nil; holding = false
    }

    fileprivate func reenable() { if let t = tap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// 返回 true = 这个按键归 Weft，系统看不到
    fileprivate func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        let flags = e.flags
        if type == .flagsChanged {
            if holding && !flags.contains(.maskControl) {
                holding = false
                MainActor.assumeIsolated { onCommit() }
            } else if !holding && flags.contains(.maskControl) {
                // 刚按下 ⌃：可能马上要按方向键，先在下一轮把窗口列表准备好（不在截取回调里做，免得拖慢按键）
                DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.enabled() == true { self?.onPress() } } }
            }
            return false
        }
        guard type == .keyDown else { return false }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if holding && code == 53 {   // Esc：不换了
            holding = false
            MainActor.assumeIsolated { onCancel() }
            return true
        }
        if holding && code == 48 {   // ⌃Tab：换屏（卡片开着的时候才接管，平时 ⌃Tab 照常给浏览器之类）
            MainActor.assumeIsolated { onTab() }
            return true
        }
        guard code == 123 || code == 124 else { return false }
        log("⌃方向键 code=\(code) flags=\(flags.rawValue) holding=\(holding)")
        // 只认「只按了 ⌃」：⌃⌥← 这类留给别的 App
        guard flags.contains(.maskControl), flags.intersection([.maskCommand, .maskAlternate, .maskShift]).isEmpty else { return false }
        if holding {
            let step = code == 124 ? 1 : -1
            MainActor.assumeIsolated { onStep(step) }
            return true
        }
        guard MainActor.assumeIsolated({ enabled() }) else { return false }
        holding = true
        // 第一下只浮出来，不挪：不然一按就已经选到下一个了
        MainActor.assumeIsolated { onOpen() }
        return true
    }
}

private func sceneKeysCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let keys = Unmanaged<SceneKeys>.fromOpaque(refcon).takeUnretainedValue()
    // 系统嫌我们处理太慢会把截取关掉：马上再打开
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        keys.reenable()
        return Unmanaged.passUnretained(event)
    }
    return keys.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}

// MARK: - 四指左右滑

/// 读触控板的原始触点（私有框架 MultitouchSupport，BetterTouchTool、MiddleClick 都是这么做的）。
/// 只读，不拦截：系统自己的四指手势照常发生（只有一个桌面时就是轻轻弹一下）。
final class SceneSwipe {
    var enabled: () -> Bool = { false }
    var onStep: (Int) -> Void = { _ in }
    var onCommit: () -> Void = {}
    /// 手指刚搭上（还没滑）：预先准备
    var onTouch: () -> Void = {}
    /// 几根手指算数
    var fingers = 4
    /// 手指横向走多远换一个场景（触控板宽度的比例）
    var stepDistance: Float = 0.08

    private(set) var running = false
    private var devices: [UnsafeMutableRawPointer] = []

    func start() {
        guard !running, let fw = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let pList = dlsym(fw, "MTDeviceCreateList"), let pReg = dlsym(fw, "MTRegisterContactFrameCallback"),
              let pStart = dlsym(fw, "MTDeviceStart") else { return }
        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        let createList = unsafeBitCast(pList, to: CreateList.self)
        let register = unsafeBitCast(pReg, to: Register.self)
        let startDev = unsafeBitCast(pStart, to: Start.self)
        guard let list = createList()?.takeRetainedValue() as? [AnyObject] else { return }
        SwipeState.shared.owner = self
        for d in list {
            let dev = Unmanaged.passRetained(d).toOpaque()
            register(dev, swipeCallback)
            startDev(dev, 0)
            devices.append(dev)
        }
        running = !devices.isEmpty
    }

    /// first：这次手势的第一步（要先问一下现在接不接管；不接管就整个手势都不管）
    fileprivate func step(_ n: Int, first: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if first && !self.enabled() { SwipeState.shared.reset(); return }
                self.onStep(n)
            }
        }
    }

    fileprivate func touched() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { if self?.enabled() == true { self?.onTouch() } } }
    }

    fileprivate func commit() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onCommit() } }
    }
}

typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

/// 手势进行中的状态（回调在触控板自己的线程上）
private final class SwipeState {
    static let shared = SwipeState()
    weak var owner: SceneSwipe?
    let lock = NSLock()
    var tracking = false
    /// 方向定了没有：0 还没定，1 横着（归 Weft），-1 竖着（调度中心之类，这次手势不管）
    var axis = 0
    var startX: Float = 0, startY: Float = 0
    var baseX: Float = 0
    var lastX: Float = 0, lastY: Float = 0
    var lastCount = 0
    /// 手指数掉下去的帧数（手指偶尔被认丢一两帧，不能当成抬手）
    var lowFrames = 0
    var stepped = false
    func reset() { lock.lock(); tracking = false; stepped = false; axis = 0; lowFrames = 0; lock.unlock() }
}

/// 每帧触点。MTTouch 结构 96 字节，归一化坐标 (x, y) 在偏移 32
private let swipeCallback: MTCallback = { _, touches, count, _, _ in
    let st = SwipeState.shared
    guard let owner = st.owner else { return 0 }
    let n = Int(count)
    st.lock.lock()
    defer { st.lock.unlock() }
    if n >= owner.fingers, let touches {
        st.lowFrames = 0
        var sx: Float = 0, sy: Float = 0
        for i in 0..<n {
            let p = touches.advanced(by: i * 96 + 32).assumingMemoryBound(to: Float.self)
            sx += p[0]; sy += p[1]
        }
        let x = sx / Float(n), y = sy / Float(n)
        if !st.tracking {
            st.tracking = true; st.axis = 0; st.stepped = false
            st.startX = x; st.startY = y; st.baseX = x; st.lastX = x; st.lastY = y; st.lastCount = n
            owner.touched()
            return 0
        }
        // 手指数变了（多搭了一根 / 少认了一根）：平均位置会跳，从这里重新算，不当成滑动
        if n != st.lastCount { st.lastCount = n; st.baseX = x - (st.lastX - st.baseX); st.startY = y - (st.lastY - st.startY); st.startX = x - (st.lastX - st.startX); st.lastX = x; st.lastY = y; return 0 }
        st.lastX = x; st.lastY = y
        // 先定方向：走出一小段后看横着多还是竖着多，定了这次手势就不再变（以前斜一点就一直不动）
        if st.axis == 0 {
            let ax = abs(x - st.startX), ay = abs(y - st.startY)
            guard max(ax, ay) >= 0.025 else { return 0 }
            st.axis = ax >= ay * 0.8 ? 1 : -1
        }
        guard st.axis == 1 else { return 0 }
        let dx = x - st.baseX
        guard abs(dx) >= owner.stepDistance else { return 0 }
        // 手指往左 = 去右边那个（和切系统桌面一样）
        owner.step(dx < 0 ? 1 : -1, first: !st.stepped)
        st.stepped = true
        st.baseX += dx < 0 ? -owner.stepDistance : owner.stepDistance   // 多出来的距离留给下一格，滑得快也不丢格
    } else if st.tracking {
        // 全抬起来了才算结束；只是少认了一两帧的手指，等等看
        st.lowFrames += 1
        guard n == 0 || st.lowFrames >= 6 else { return 0 }
        st.tracking = false
        st.axis = 0
        if st.stepped { st.stepped = false; owner.commit() }
    }
    return 0
}
