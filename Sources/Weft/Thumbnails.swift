import AppKit
import ScreenCaptureKit
import WeftCore

/// 窗口缩略图（ScreenCaptureKit，需要录屏权限）。只截图做预览，不录制、不保存到磁盘。
@MainActor
final class ThumbnailService {
    private(set) var cache: [UInt32: NSImage] = [:]
    private var inflight = false

    var available: Bool { Permissions.screenCapture }

    /// 关掉的窗口的缩略图扔掉（以前一直留着，开开关关一天能攒几百 MB）
    func prune(keep: Set<UInt32>) {
        for k in Array(cache.keys) where !keep.contains(k) { cache[k] = nil }
    }

    /// 刷新指定窗口的缩略图，完成后回调（主线程）
    func refresh(_ ids: [UInt32], maxWidth: CGFloat = 520, done: @escaping ([UInt32: NSImage]) -> Void) {
        guard available, !ids.isEmpty, !inflight else { return }
        inflight = true
        let want = Set(ids)
        Task { @MainActor in
            defer { self.inflight = false }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            let targets = content.windows.filter { want.contains($0.windowID) && $0.frame.width > 60 }
            var results: [UInt32: NSImage] = [:]
            await withTaskGroup(of: (UInt32, CGImage?).self) { group in
                for w in targets {
                    group.addTask {
                        let filter = SCContentFilter(desktopIndependentWindow: w)
                        let cfg = SCStreamConfiguration()
                        let scale = min(1, maxWidth / max(w.frame.width, 1))
                        cfg.width = Int(w.frame.width * scale * 2)
                        cfg.height = Int(w.frame.height * scale * 2)
                        cfg.showsCursor = false
                        cfg.ignoreShadowsSingleWindow = true
                        let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
                        return (w.windowID, img)
                    }
                }
                for await (id, img) in group {
                    if let img { results[id] = NSImage(cgImage: img, size: NSSize(width: img.width / 2, height: img.height / 2)) }
                }
            }
            for (k, v) in results { self.cache[k] = v }
            done(results)
        }
    }
}
