import CoreGraphics
import Foundation

/// 一个真实窗口的快照。坐标统一使用 CG 全局坐标（主屏左上角为原点，y 向下）。
public struct WindowInfo: Codable, Equatable, Identifiable {
    public var id: UInt32            // CGWindowID
    public var pid: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var frame: CGRect
    public var displayUUID: String?  // 窗口中心所在的显示器
    public var isMinimized: Bool
    /// 是否能通过 AX 直接操作（不在当前 Space 的窗口通常拿不到 AX 句柄）
    public var axAvailable: Bool
    /// z 序（0 = 最前），用作「最近使用」的近似
    public var zIndex: Int
    /// 固定尺寸、改不了大小的窗口（弹窗、付款确认页、部分设置窗口）。nil = 可以改
    public var fixedSize: Bool?

    public init(id: UInt32, pid: Int32, bundleID: String, appName: String, title: String,
                frame: CGRect, displayUUID: String? = nil, isMinimized: Bool = false,
                axAvailable: Bool = true, zIndex: Int = 0) {
        self.id = id; self.pid = pid; self.bundleID = bundleID; self.appName = appName
        self.title = title; self.frame = frame; self.displayUUID = displayUUID
        self.isMinimized = isMinimized; self.axAvailable = axAvailable; self.zIndex = zIndex
    }
}

public struct DisplayInfo: Codable, Equatable {
    public var id: UInt32
    public var uuid: String
    public var name: String
    public var frame: CGRect      // CG 坐标
    public var visible: CGRect    // 去掉菜单栏 / Dock 后的可用区域（CG 坐标）
    public var isMain: Bool
    public var isBuiltin: Bool

    public init(id: UInt32, uuid: String, name: String, frame: CGRect, visible: CGRect,
                isMain: Bool, isBuiltin: Bool) {
        self.id = id; self.uuid = uuid; self.name = name; self.frame = frame
        self.visible = visible; self.isMain = isMain; self.isBuiltin = isBuiltin
    }
}

/// 当前接了哪些显示器。fingerprint 相同 = 同一种工作场景（如「只有笔记本」「笔记本+公司 4K」）。
public struct DisplayProfile: Codable, Equatable {
    public var displays: [DisplayInfo]

    public init(displays: [DisplayInfo]) { self.displays = displays }

    public var fingerprint: String {
        displays
            .map { "\($0.uuid)@\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .sorted()
            .joined(separator: "+")
    }

    public var main: DisplayInfo? { displays.first(where: { $0.isMain }) ?? displays.first }

    public func display(uuid: String?) -> DisplayInfo? {
        guard let uuid else { return nil }
        return displays.first(where: { $0.uuid == uuid })
    }

    /// 包含该点的显示器；都不包含时取最近的一块
    public func display(containing p: CGPoint) -> DisplayInfo? {
        if let d = displays.first(where: { $0.frame.contains(p) }) { return d }
        return displays.min(by: { $0.frame.distance(to: p) < $1.frame.distance(to: p) })
    }

    public var summary: String {
        displays.map { "\($0.name)\($0.isMain ? "(主)" : "") \(Int($0.frame.width))×\(Int($0.frame.height))" }
            .joined(separator: " + ")
    }
}

extension CGRect {
    public var center: CGPoint { CGPoint(x: midX, y: midY) }

    func distance(to p: CGPoint) -> CGFloat {
        let dx = max(minX - p.x, 0, p.x - maxX)
        let dy = max(minY - p.y, 0, p.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// 以 container 为基准的相对坐标（0…1）
    public func relative(to container: CGRect) -> CGRect {
        guard container.width > 0, container.height > 0 else { return .zero }
        return CGRect(x: (minX - container.minX) / container.width,
                      y: (minY - container.minY) / container.height,
                      width: width / container.width,
                      height: height / container.height)
    }

    /// 把相对坐标还原到 container 中
    public func absolute(in container: CGRect) -> CGRect {
        CGRect(x: container.minX + minX * container.width,
               y: container.minY + minY * container.height,
               width: width * container.width,
               height: height * container.height).integral
    }

    /// 尽量保持尺寸，把矩形挪进 bounds 内
    public func clamped(to bounds: CGRect) -> CGRect {
        var r = self
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }
}


// MARK: - 屏幕的「位置」：笔记本 / 扩展屏1 / 扩展屏2
//
// 场景归的是位置，不是某一台具体的显示器：白天接公司的屏、晚上接家里的屏，都是「扩展屏1」，场景跟着走。
// 外接屏按从左到右（同一列从上到下）排号；合盖只接外接屏时没有「笔记本」。
public extension DisplayProfile {
    static let laptopRole = "laptop"

    /// 位置 → 显示器 uuid
    var roleMap: [String: String] {
        var out: [String: String] = [:]
        if let b = displays.first(where: \.isBuiltin) { out[Self.laptopRole] = b.uuid }
        let ext = displays.filter { !$0.isBuiltin }.sorted { ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY) }
        for (i, d) in ext.enumerated() { out["ext\(i + 1)"] = d.uuid }
        return out
    }

    func role(of uuid: String) -> String? { roleMap.first { $0.value == uuid }?.key }
    func display(forRole r: String) -> DisplayInfo? { roleMap[r].flatMap { display(uuid: $0) } }

    /// 笔记本 / 扩展屏1
    static func roleName(_ r: String) -> String {
        if r == laptopRole { return "笔记本" }
        if r.hasPrefix("ext") { return "扩展屏" + r.dropFirst(3) }
        return r
    }

    /// 排序用：笔记本在前，扩展屏按号
    static func roleOrder(_ r: String) -> Int { r == laptopRole ? 0 : Int(r.dropFirst(3)) ?? 99 }
}
