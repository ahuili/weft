import CoreGraphics
import Foundation

/// 本地持久化：~/Library/Application Support/Weft/
public final class Store {
    public static let shared = Store()

    public let dir: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Weft", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
    }

    public func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    public func save<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: dir.appendingPathComponent(name), options: .atomic)
    }
}

/// 每种显示器组合存两份布局：手动保存的（优先）+ 自动保存的
public struct LayoutDB: Codable {
    public var manual: [String: Layout] = [:]
    public var auto: [String: Layout] = [:]

    public init() {}

    public func best(for fingerprint: String) -> Layout? { manual[fingerprint] ?? auto[fingerprint] }

    /// 最近一次自动保存（不论哪种显示器组合），用于降级映射
    public var latestAuto: Layout? { auto.values.max(by: { $0.savedAt < $1.savedAt }) }
}

/// 撤销栈：每次自动 / AI 改动前拍快照
public final class UndoStack {
    public struct Snapshot {
        public var label: String
        public var frames: [UInt32: (CGRect, Bool)]
    }

    private(set) public var items: [Snapshot] = []
    public init() {}

    public func push(_ label: String, windows: [WindowInfo]) {
        var m: [UInt32: (CGRect, Bool)] = [:]
        for w in windows where w.axAvailable { m[w.id] = (w.frame, w.isMinimized) }
        items.append(Snapshot(label: label, frames: m))
        if items.count > 30 { items.removeFirst() }
    }

    public var canUndo: Bool { !items.isEmpty }
    public var lastLabel: String? { items.last?.label }

    @discardableResult
    public func undo(using actions: WindowActions) -> String? {
        guard let s = items.popLast() else { return nil }
        let current = Dictionary(actions.windows().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for (id, (frame, minimized)) in s.frames {
            guard let w = current[id] else { continue }
            if w.isMinimized != minimized { actions.setMinimized(id, minimized) }
            if !minimized && !w.frame.isClose(to: frame) { actions.setFrame(id, frame) }
        }
        return s.label
    }
}

/// 执行一组 Move
public enum Executor {
    @discardableResult
    public static func apply(_ moves: [Move], using actions: WindowActions) -> Int {
        var n = 0
        for m in moves {
            if let min = m.minimize {
                actions.setMinimized(m.windowID, min)
                if min { n += 1; continue }
            }
            if actions.setFrame(m.windowID, m.frame) { n += 1 }
        }
        return n
    }
}
