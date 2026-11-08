import AppKit

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ wids: CFArray) -> Unmanaged<CFArray>?
import ApplicationServices
import CoreGraphics

/// 私有但被 AltTab / yabai / Rectangle 等广泛使用的 API：AX 元素 → CGWindowID
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// 窗口操作的抽象。真实实现走 AX；测试 / AI 演练用假实现。
public protocol WindowActions: AnyObject {
    func windows() -> [WindowInfo]
    func profile() -> DisplayProfile
    @discardableResult func focus(_ id: UInt32) -> Bool
    @discardableResult func setFrame(_ id: UInt32, _ frame: CGRect) -> Bool
    @discardableResult func setMinimized(_ id: UInt32, _ minimized: Bool) -> Bool
    /// 窗口是否还存在（关掉才算不存在；锁屏、切桌面时看不到不算）
    func exists(_ id: UInt32) -> Bool
    /// 现在能不能可靠地看到窗口（锁屏、登录窗口在前面时不能）
    var canObserve: Bool { get }
    /// 只要位置（便宜）：排版后校验用
    func frames(of ids: [UInt32]) -> [UInt32: CGRect]
    /// 每块屏现在显示的是第几个系统桌面（Space id）
    func displaySpaces() -> [String: Int]
}

public extension WindowActions {
    func displaySpaces() -> [String: Int] { [:] }
    func exists(_ id: UInt32) -> Bool { windows().contains { $0.id == id } }
    var canObserve: Bool { true }
    func frames(of ids: [UInt32]) -> [UInt32: CGRect] {
        let set = Set(ids)
        return Dictionary(windows().filter { set.contains($0.id) }.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
    }
}

public enum Permissions {
    public static var accessibility: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示
    public static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 录屏权限：仅用于读取「其他桌面」窗口的标题，可选
    public static var screenCapture: Bool { CGPreflightScreenCaptureAccess() }
    public static func requestScreenCapture() { _ = CGRequestScreenCaptureAccess() }
}

public final class SystemWindows: WindowActions {
    public init() {}

    /// 缓存 id → AX 元素，供后续操作使用
    private var axCache: [UInt32: AXUIElement] = [:]
    private let ignoredBundles: Set<String> = [
        "com.apple.dock", "com.apple.WindowManager", "com.apple.controlcenter",
        "com.apple.notificationcenterui", "com.apple.Spotlight",
    ]

    // MARK: - 显示器

    public func profile() -> DisplayProfile {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let mainID = CGMainDisplayID()
        let displays: [DisplayInfo] = NSScreen.screens.compactMap { s in
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(num.uint32Value)
            let uuid: String
            if let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                uuid = CFUUIDCreateString(nil, u) as String
            } else {
                uuid = "display-\(id)"
            }
            return DisplayInfo(id: id, uuid: uuid, name: s.localizedName,
                               frame: Self.toCG(s.frame, primaryHeight: primaryHeight),
                               visible: Self.toCG(s.visibleFrame, primaryHeight: primaryHeight),
                               isMain: id == mainID, isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        return DisplayProfile(displays: displays)
    }

    /// NSScreen（左下原点）→ CG（左上原点）
    static func toCG(_ r: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - 窗口

    // MARK: 缓存
    //
    // 逐个 App 问 AX 拿窗口很慢（20 多个 App 要 ~190ms，卡主线程）。
    // 改成：每个 App 读一次就缓存，靠 AX 通知（新建 / 关闭 / 改标题 / 最小化）把它标「脏」，下次只重读脏的那几个；
    // 位置和尺寸每次从窗口服务器（CG）取，几毫秒，不用问 App。

    private struct AXEntry {
        var id: UInt32
        var element: AXUIElement
        var title: String
        var minimized: Bool
        var fixed: Bool
        var axFrame: CGRect
    }
    private let lock = NSRecursiveLock()
    private var appEntries: [pid_t: [AXEntry]] = [:]
    private var appReadAt: [pid_t: Date] = [:]
    private var policyCache: [pid_t: NSApplication.ActivationPolicy] = [:]
    private var policyAt = Date.distantPast
    private var dirty = Set<pid_t>()
    private var observers: [pid_t: AXObserver] = [:]
    private var watched = Set<UInt32>()
    private var last: [UInt32: WindowInfo] = [:]
    /// 没收到通知也会定期重读一次（有的 App 不发通知），每轮最多重读几个，摊开开销
    public var staleAfter: TimeInterval = 20
    /// 窗口列表变了（AX 通知）：界面可以据此刷新
    public var onChange: () -> Void = {}

    func markDirty(_ pid: pid_t) {
        lock.lock(); dirty.insert(pid); lock.unlock()
    }

    private static let appNotes = [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification]
    private static let windowNotes = [kAXUIElementDestroyedNotification, kAXTitleChangedNotification,
                                      kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification]

    private func observe(_ pid: pid_t, _ axApp: AXUIElement) -> AXObserver? {
        if let o = observers[pid] { return o }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, note, refcon in
            guard let refcon else { return }
            let me = Unmanaged<SystemWindows>.fromOpaque(refcon).takeUnretainedValue()
            // 焦点变化不影响窗口列表，不标脏
            if (note as String) == (kAXFocusedWindowChangedNotification as String) { me.onFocusNote(); return }
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid > 0 { me.markDirty(pid) }
            me.dirtyFromCallback()
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let obs else { return nil }
        let ref = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.appNotes { AXObserverAddNotification(obs, axApp, n as CFString, ref) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observers[pid] = obs
        return obs
    }

    /// 有变化：合并成一次 onChange（同一轮里来十个通知也只刷新一次）
    private var pendingNote = false
    private func dirtyFromCallback() {
        lock.lock(); anyChange = true; lock.unlock()
        if !pendingNote {
            pendingNote = true
            DispatchQueue.main.async { [weak self] in self?.pendingNote = false; self?.onChange() }
        }
    }
    private var anyChange = false
    /// 焦点切换（⌘Tab、点窗口）：舞台模式靠它即时响应，不用等轮询
    public var onFocusChange: () -> Void = {}
    private func onFocusNote() { DispatchQueue.main.async { [weak self] in self?.onFocusChange() } }

    public func windows() -> [WindowInfo] {
        lock.lock(); defer { lock.unlock() }
        let prof = profile()
        // 1) CG：所有桌面的普通窗口（layer 0），按 z 序从前到后
        let opts: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let cgList = (CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]) ?? []
        var cgByID: [UInt32: (pid: Int32, bounds: CGRect, name: String, onScreen: Bool, z: Int)] = [:]
        for (z, item) in cgList.enumerated() {
            guard (item[kCGWindowLayer as String] as? Int) == 0,
                  let id = item[kCGWindowNumber as String] as? UInt32,
                  let pid = item[kCGWindowOwnerPID as String] as? Int32,
                  let bd = item[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: bd),
                  bounds.width >= 60, bounds.height >= 40
            else { continue }
            let alpha = item[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { continue }
            cgByID[id] = (pid, bounds, item[kCGWindowName as String] as? String ?? "",
                          item[kCGWindowIsOnscreen as String] as? Bool ?? false, z)
        }

        // 2) AX：能拿到句柄的窗口（当前桌面 + 最小化），拿真实标题 / 状态。只重读有变化的 App
        var result: [UInt32: WindowInfo] = [:]
        // 普通 App + 有正常大窗口的「菜单栏 App」（magpie 这类没有 Dock 图标、但开着主窗口的）。
        // 以前只认普通 App，菜单栏 App 的窗口舞台藏不掉、一直躲在后面
        let cgPIDs = Set(cgByID.values.filter { $0.bounds.width >= 400 && $0.bounds.height >= 300 }.map(\.pid))
        let me = ProcessInfo.processInfo.processIdentifier
        // activationPolicy 每问一次都要跨进程问 LaunchServices（一百多个进程就是一百多次）：按进程缓存，10 秒刷新一次
        let now0 = Date()
        if now0.timeIntervalSince(policyAt) > 10 { policyCache.removeAll(); policyAt = now0 }
        let apps = NSWorkspace.shared.runningApplications.filter { a in
            let pid = a.processIdentifier
            guard pid != me else { return false }
            let pol = policyCache[pid] ?? { let p = a.activationPolicy; policyCache[pid] = p; return p }()
            return (pol == .regular || (pol == .accessory && cgPIDs.contains(pid))) && !ignoredBundles.contains(a.bundleIdentifier ?? "")
        }
        let appByPID = Dictionary(apps.map { ($0.processIdentifier, $0) }, uniquingKeysWith: { a, _ in a })
        // 退出了的 App：丢掉缓存
        for pid in Array(appEntries.keys) where appByPID[pid] == nil {
            for e in appEntries[pid] ?? [] { axCache[e.id] = nil; watched.remove(e.id) }
            appEntries[pid] = nil; appReadAt[pid] = nil
            if let o = observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
            }
        }

        if Permissions.accessibility {
            // 有 AX 通知但不知道是哪个 App：看 CG 里窗口集合变了的 App（新建 / 关闭）+ 标题变了的
            if anyChange {
                anyChange = false
                for app in apps {
                    let pid = app.processIdentifier
                    guard let cached = appEntries[pid] else { continue }
                    let cgIDs = Set(cgByID.filter { $0.value.pid == pid && $0.value.onScreen }.map(\.key))
                    let known = Set(cached.filter { !$0.minimized }.map(\.id))
                    // 当前桌面上看得见的窗口集合变了 → 重读
                    if !cgIDs.subtracting(known).isEmpty || !known.subtracting(cgByID.keys).isEmpty { dirty.insert(pid) }
                    // 标题变了（CG 有录屏权限时能看到标题）
                    for e in cached { if let c = cgByID[e.id], !c.name.isEmpty, c.name != e.title { dirty.insert(pid); break } }
                }
                // 最小化 / 还原：CG 的 onScreen 和缓存对不上
                for app in apps {
                    let pid = app.processIdentifier
                    for e in appEntries[pid] ?? [] {
                        if let c = cgByID[e.id], c.onScreen == e.minimized { dirty.insert(pid); break }
                    }
                }
            }
            let now = Date()
            var staleBudget = 2
            for app in apps {
                let pid = app.processIdentifier
                var need = appEntries[pid] == nil || dirty.contains(pid)
                if !need, let t = appReadAt[pid], now.timeIntervalSince(t) > staleAfter, staleBudget > 0 { need = true; staleBudget -= 1 }
                if need {
                    // 读失败（App 卡住、锁屏）：保留上一次的结果，不当成「窗口都关了」
                    if let fresh = readApp(pid) { appEntries[pid] = fresh }
                    appReadAt[pid] = now
                    dirty.remove(pid)
                }
                for e in appEntries[pid] ?? [] {
                    // 位置、尺寸用 CG 的（实时、便宜）；CG 没有的（极少）用读 AX 时记下的
                    let frame = cgByID[e.id]?.bounds ?? e.axFrame
                    guard frame.width >= 60, frame.height >= 40 else { continue }
                    axCache[e.id] = e.element
                    var w = WindowInfo(
                        id: e.id, pid: pid, bundleID: app.bundleIdentifier ?? "",
                        appName: app.localizedName ?? "", title: e.title, frame: frame,
                        displayUUID: prof.display(containing: frame.center)?.uuid,
                        isMinimized: e.minimized, axAvailable: true,
                        zIndex: cgByID[e.id]?.z ?? 10_000)
                    if e.fixed { w.fixedSize = true }
                    result[e.id] = w
                }
            }
        }

        // 3) 只有 CG 能看到的窗口（通常在其他桌面）
        let current = SystemWindows.currentSpaces()
        for (id, c) in cgByID where result[id] == nil {
            guard let app = appByPID[c.pid] else { continue }
            // 当前屏可见却拿不到 AX 句柄的多半是浮层；
            // 没有标题的（未授予录屏权限，或是 App 的隐藏辅助窗口）无法辨认，也跳过
            if c.onScreen && Permissions.accessibility { continue }
            if c.name.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // 不属于任何桌面的 = App 预先建好、但没显示出来的隐藏窗口（钉钉的 ConvTabListView 之类），点了也没反应
            if !SystemWindows.isOnAnySpace(id) { continue }
            // 在「正在显示的桌面」上却不在屏幕上 = 隐藏窗口（微信那个 280×380 的小窗之类），不是在别的桌面
            if !c.onScreen, SystemWindows.spaces(of: id).isSubset(of: current), !current.isEmpty { continue }
            result[id] = WindowInfo(
                id: id, pid: c.pid, bundleID: app.bundleIdentifier ?? "", appName: app.localizedName ?? "",
                title: c.name, frame: c.bounds, displayUUID: prof.display(containing: c.bounds.center)?.uuid,
                isMinimized: false, axAvailable: false, zIndex: c.z + 20_000)
        }
        last = result
        return result.values.sorted { $0.zIndex < $1.zIndex }
    }

    /// 调试：直接问一个 App 的窗口，带错误码
    public func debugRead(_ pid: pid_t) -> String {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 1.0)
        var raw: CFTypeRef?
        let t = Date()
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
        var out = "pid \(pid) err=\(err.rawValue) \(Int(Date().timeIntervalSince(t) * 1000))ms count=\((raw as? [AXUIElement])?.count ?? -1) cached=\(appEntries[pid]?.count ?? -1) dirty=\(dirty.contains(pid))\n"
        for w in (raw as? [AXUIElement]) ?? [] {
            var wid: CGWindowID = 0
            _ = _AXUIElementGetWindow(w, &wid)
            let sub: String = w.attr(kAXSubroleAttribute) ?? "nil"
            out += "  \(wid) sub=\(sub) title=\((w.attr(kAXTitleAttribute) as String?) ?? "")\n"
        }
        return out
    }

    /// 读一个 App 的全部窗口（慢路径）
    private func readApp(_ pid: pid_t) -> [AXEntry]? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.3)
        let obs = observe(pid, axApp)
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &raw)
        // 没有窗口的 App 会返回空数组或 noValue；超时 / 无法通信才算「读失败」
        if err == .cannotComplete || err == .apiDisabled || err == .notImplemented { return nil }
        guard err == .success, let axWins = raw as? [AXUIElement] else { return [] }
        // 锁屏 / 屏保时 AX 会回一堆「没有窗口号」的假窗口：当成读失败，保留上一次的结果
        if !axWins.isEmpty && !canObserve { return nil }
        var out: [AXEntry] = []
        var zero = 0
        for w in axWins {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { zero += 1; continue }
            let subrole: String? = w.attr(kAXSubroleAttribute)
            guard subrole == nil || subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String)
            else { continue }
            var settable: DarwinBoolean = true
            AXUIElementIsAttributeSettable(w, kAXSizeAttribute as CFString, &settable)
            out.append(AXEntry(id: wid, element: w, title: w.attr(kAXTitleAttribute) ?? "",
                               minimized: w.attr(kAXMinimizedAttribute) ?? false, fixed: !settable.boolValue,
                               axFrame: w.frame ?? .zero))
            if let obs, !watched.contains(wid) {
                let ref = Unmanaged.passUnretained(self).toOpaque()
                for n in Self.windowNotes { AXObserverAddNotification(obs, w, n as CFString, ref) }
                watched.insert(wid)
            }
        }
        // 有窗口但一个窗口号都拿不到 = 读坏了（锁屏、App 卡住），别当成「没有窗口」缓存起来
        if out.isEmpty && zero > 0 { return nil }
        return out
    }

    /// 窗口的最新位置（只问窗口服务器，~1ms）。给舞台排完版后校验用
    public func frames(of ids: [UInt32]) -> [UInt32: CGRect] {
        guard !ids.isEmpty else { return [:] }
        // 这个 API 要的是「窗口号本身」组成的数组（指针值），传 NSNumber 会什么都拿不到
        var values: [UnsafeRawPointer?] = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let arr = CFArrayCreate(nil, &values, values.count, nil),
              let list = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else { return [:] }
        var out: [UInt32: CGRect] = [:]
        for item in list {
            guard let id = item[kCGWindowNumber as String] as? UInt32,
                  let bd = item[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bd) else { continue }
            out[id] = b
        }
        return out
    }

    /// 上一次枚举的结果（不重新枚举）
    public func lastKnown(_ id: UInt32) -> WindowInfo? { lock.lock(); defer { lock.unlock() }; return last[id] }

    static func spaces(of id: UInt32) -> Set<Int> {
        Set((CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] ?? []).map(\.intValue))
    }

    /// 每块屏幕当前显示的桌面
    static func currentSpaces() -> Set<Int> {
        guard let arr = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return Set(arr.compactMap { ($0["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int })
    }

    /// 问窗口服务器：这个窗口还在不在（不受锁屏 / 桌面 / AX 影响）
    public func exists(_ id: UInt32) -> Bool {
        guard let arr = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]] else { return true }
        return !arr.isEmpty
    }

    /// 锁屏 / 登录窗口在前面时，AX 拿不到窗口：这时不做任何「窗口没了」的判断
    public func displaySpaces() -> [String: Int] {
        guard let arr = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] else { return [:] }
        let prof = profile()
        var out: [String: Int] = [:]
        for d in arr {
            guard let sid = (d["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? Int else { continue }
            let id = d["Display Identifier"] as? String ?? ""
            // 「显示器使用独立空间」关掉时只有一个 "Main"：所有屏共用
            if id == "Main" { for x in prof.displays { out[x.uuid] = sid } } else { out[id] = sid }
        }
        return out
    }

    public var canObserve: Bool {
        if let d = CGSessionCopyCurrentDictionary() as? [String: Any] {
            if (d["CGSSessionScreenIsLocked"] as? Bool) == true { return false }
            if (d[kCGSessionOnConsoleKey as String] as? Bool) == false { return false }
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier != "com.apple.loginwindow"
    }

    /// 窗口是否属于某个桌面（Space）。隐藏 / 未显示的窗口返回空
    public static func isOnAnySpace(_ id: UInt32) -> Bool {
        guard let arr = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [id] as CFArray)?.takeRetainedValue() as? [Any]
        else { return true }
        return !arr.isEmpty
    }

    /// 当前聚焦的窗口
    public func focusedWindowID() -> UInt32? {
        let sys = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = sys.attr(kAXFocusedApplicationAttribute),
              let w: AXUIElement = app.attr(kAXFocusedWindowAttribute) else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { return nil }
        axCache[wid] = w
        return wid
    }

    /// 当前聚焦窗口的轻量信息（不枚举全部窗口，供每秒一次的习惯记录使用）
    public func focusedWindow() -> WindowInfo? {
        guard Permissions.accessibility,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard let w: AXUIElement = axApp.attr(kAXFocusedWindowAttribute) else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { return nil }
        axCache[wid] = w
        return WindowInfo(id: wid, pid: app.processIdentifier, bundleID: app.bundleIdentifier ?? "",
                          appName: app.localizedName ?? "", title: w.attr(kAXTitleAttribute) ?? "",
                          frame: w.frame ?? .zero)
    }

    // MARK: - 操作

    private func element(_ id: UInt32) -> AXUIElement? {
        if let e = axCache[id] { return e }
        _ = windows()
        return axCache[id]
    }

    @discardableResult
    public func focus(_ id: UInt32) -> Bool {
        let info = lastKnown(id) ?? windows().first(where: { $0.id == id })
        guard let info, let app = NSRunningApplication(processIdentifier: info.pid) else { return false }
        // macOS 14+ 的「协作式激活」可能拒绝后台 App 调用 activate()，再用 AX 置前兜底
        let axApp = AXUIElementCreateApplication(info.pid)
        if let e = element(id) {
            if info.isMinimized { AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            app.activate(options: [])
            AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(e, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(e, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return true
        }
        // 不在当前桌面：先激活 App（系统会切到它所在的桌面），再补一次 raise
        app.activate(options: [])
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if let e = self?.element(id) { AXUIElementPerformAction(e, kAXRaiseAction as CFString) }
        }
        return true
    }

    public func isCached(_ id: UInt32) -> Bool { axCache[id] != nil }

    /// 快速聚焦：只用缓存里的 AX 句柄，不枚举全部窗口（数字槽位要「按下即到」）。句柄失效返回 false
    @discardableResult
    public func quickFocus(_ id: UInt32) -> Bool {
        guard let e = axCache[id] else { return false }
        var role: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &role) == .success else { axCache[id] = nil; return false }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if (e.attr(kAXMinimizedAttribute) as Bool?) == true { AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
        app.activate(options: [])
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// 点窗口的关闭按钮（和用户手点一样：有未保存内容时 App 会自己弹窗确认）
    @discardableResult
    public func close(_ id: UInt32) -> Bool {
        guard let e = element(id), let b: AXUIElement = e.attr(kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(b, kAXPressAction as CFString) == .success
    }

    @discardableResult
    public func setFrame(_ id: UInt32, _ frame: CGRect) -> Bool {
        guard let e = element(id) else { return false }
        // Chrome / Electron 在 AXEnhancedUserInterface 打开时会拒绝变大、还带动画（Rectangle、yabai 也是这么处理的）：
        // 改之前先关掉，改完恢复
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        let app = AXUIElementCreateApplication(pid)
        let key = "AXEnhancedUserInterface" as CFString
        var cur: CFTypeRef?
        let enhanced = AXUIElementCopyAttributeValue(app, key, &cur) == .success && (cur as? Bool) == true
        if enhanced { AXUIElementSetAttributeValue(app, key, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, key, kCFBooleanTrue) } }
        // 尺寸 → 位置 → 尺寸：跨屏时避免被旧屏幕尺寸限制，变大时避免被屏幕边缘挡住
        e.setSize(frame.size)
        e.setPosition(frame.origin)
        e.setSize(frame.size)
        if let f = e.frame, abs(f.minX - frame.minX) > 2 || abs(f.minY - frame.minY) > 2 { e.setPosition(frame.origin) }
        return true
    }

    @discardableResult
    public func setMinimized(_ id: UInt32, _ minimized: Bool) -> Bool {
        guard let e = element(id) else { return false }
        return AXUIElementSetAttributeValue(e, kAXMinimizedAttribute as CFString,
                                            minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }
}

// MARK: - AX 便捷封装

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    var frame: CGRect? {
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(self, kAXSizeAttribute as CFString, &sv) == .success,
              let pv, let sv else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    func setPosition(_ p: CGPoint) {
        var p = p
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(self, kAXPositionAttribute as CFString, v) }
    }

    func setSize(_ s: CGSize) {
        var s = s
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(self, kAXSizeAttribute as CFString, v) }
    }
}
