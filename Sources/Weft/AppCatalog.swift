import AppKit
import SwiftUI
import WeftCore

// MARK: - 搜 App
//
// 搜窗口时，App 退了（或开着但一个窗口都没有）就搜不到。这里把装在这台 Mac 上的 App 也列进搜索：
// 没有窗口的 App 单独排在窗口结果下面，点一下 / 回车就打开它（开着的就让它新开一个窗口）。

struct AppEntry: Identifiable, Hashable {
    let id: String          // bundleID
    let name: String        // 本地化的名字（微信、访达）
    let altName: String     // 英文名 / CFBundleName（WeChat、Finder）
    let url: URL
    var running: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty }
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

@MainActor
final class AppCatalog {
    static let shared = AppCatalog()
    private(set) var all: [AppEntry] = []
    private var scannedAt = Date.distantPast

    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                          NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]
    static let extras = ["/System/Library/CoreServices/Finder.app"]

    /// 5 分钟内扫过就不再扫（装了新 App 最多晚 5 分钟出现）
    func refreshIfStale() { if Date().timeIntervalSince(scannedAt) > 300 { scan() } }

    func scan() {
        scannedAt = Date()
        var seen = Set<String>(), out: [AppEntry] = []
        func add(_ url: URL) {
            guard let b = Bundle(url: url), let id = b.bundleIdentifier, !seen.contains(id) else { return }
            // 不列后台小工具（没有 Dock 图标的）
            if (b.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) == true { return }
            seen.insert(id)
            // 用 Spotlight 的显示名（跟着系统语言：计算器 / 访达），拿不到再用文件名
            let md = MDItemCreate(nil, url.path as CFString).flatMap { MDItemCopyAttribute($0, kMDItemDisplayName) as? String }
            let display = (md ?? FileManager.default.displayName(atPath: url.path)).replacingOccurrences(of: ".app", with: "")
            let raw = (b.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? url.deletingPathExtension().lastPathComponent
            out.append(AppEntry(id: id, name: display, altName: raw, url: url))
        }
        let fm = FileManager.default
        for dir in Self.folders {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil) else { continue }
            for u in items where u.pathExtension == "app" { add(u) }
            // 装在子文件夹里的（比如 /Applications/Setapp/xxx.app）多看一层
            for u in items where u.pathExtension.isEmpty {
                for v in (try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? [] where v.pathExtension == "app" { add(v) }
            }
        }
        for p in Self.extras { add(URL(fileURLWithPath: p)) }
        // 正在运行、但不在这些文件夹里的 App
        for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular { if let u = r.bundleURL { add(u) } }
        all = out
    }

    /// 和搜索词匹配、而且现在没有窗口的 App
    func search(_ query: String, windows: [WindowInfo], limit: Int = 5) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        refreshIfStale()
        let withWindows = Set(windows.map(\.bundleID))
        return all.compactMap { a -> (AppEntry, Double)? in
            guard !withWindows.contains(a.id), a.id != Bundle.main.bundleIdentifier,
                  let s = FuzzyMatcher.score(query: q, candidates: [a.name, a.altName, a.url.deletingPathExtension().lastPathComponent, a.id]) else { return nil }
            return (a, s)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map(\.0)
    }

    static func open(_ a: AppEntry) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: a.url, configuration: cfg) { _, err in
            if let err { DispatchQueue.main.async { Toast.show("打不开 \(a.name)：\(err.localizedDescription)", seconds: 2) } }
        }
        Toast.show(a.running ? "\(a.name) 开着但没有窗口：让它新开一个" : "正在打开 \(a.name)…", seconds: 1.4)
    }
}

/// 搜索结果里的一行 App（没有窗口的）
struct AppRow: View {
    let app: AppEntry
    var compact = false
    var number: Int? = nil
    var open: (AppEntry) -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            if let number { Text("\(number)").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.purple).frame(width: 14) }
            Image(nsImage: app.icon).resizable().frame(width: compact ? 22 : 28, height: compact ? 22 : 28).opacity(app.running ? 1 : 0.75)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.system(size: compact ? 12 : 13, weight: .medium)).lineLimit(1)
                Text(app.running ? "开着，但没有窗口 · 点一下新开一个" : "没在运行 · 点一下打开")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: app.running ? "plus.rectangle.on.rectangle" : "arrow.up.forward.app")
                .font(.system(size: 12)).foregroundStyle(hover ? Color.accentColor : .secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Color.accentColor.opacity(0.18) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { open(app) }
    }
}
