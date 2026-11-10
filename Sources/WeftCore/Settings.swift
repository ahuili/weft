import Foundation

/// 单独一个修饰键（区分左右）。双击触发用。
public enum ModKey: String, Codable, CaseIterable {
    case rightOption, leftOption, rightCommand, leftCommand, leftControl, rightControl, leftShift, rightShift

    /// flagsChanged 事件里的 keyCode
    public var keyCode: UInt16 {
        switch self {
        case .leftOption: return 58
        case .rightOption: return 61
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftControl: return 59
        case .rightControl: return 62
        case .leftShift: return 56
        case .rightShift: return 60
        }
    }

    public var symbol: String {
        switch self {
        case .leftOption: return "左 ⌥"
        case .rightOption: return "右 ⌥"
        case .leftCommand: return "左 ⌘"
        case .rightCommand: return "右 ⌘"
        case .leftControl: return "左 ⌃"
        case .rightControl: return "右 ⌃"
        case .leftShift: return "左 ⇧"
        case .rightShift: return "右 ⇧"
        }
    }

    /// 冲突风险说明（给引导页用）
    public var note: String {
        switch self {
        case .rightOption: return "几乎没有软件占用，推荐"
        case .rightCommand: return "很少被占用；如果你用右 ⌘ 切输入法就别选"
        case .leftOption: return "Alfred、部分 IDE 也用双击 ⌥"
        case .leftCommand: return "打字时容易误触"
        case .leftControl, .rightControl: return "Mac 键盘一般只有左 ⌃"
        case .leftShift, .rightShift: return "JetBrains 系 IDE 的「随处搜索」占用了双击 ⇧"
        }
    }
}

/// 一个组合键。modifiers 用 Carbon 的位（cmdKey=0x100, shiftKey=0x200, optionKey=0x800, controlKey=0x1000）
public struct KeyCombo: Codable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var display: String
    public init(keyCode: UInt32, modifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.display = display
    }

    public static let cmd: UInt32 = 0x100, shift: UInt32 = 0x200, option: UInt32 = 0x800, control: UInt32 = 0x1000
    public static let optionTab = KeyCombo(keyCode: 48, modifiers: option, display: "⌥ Tab")
}

public enum Trigger: Codable, Equatable {
    case doubleTap(ModKey)
    case combo(KeyCombo)
    case off

    public var display: String {
        switch self {
        case .doubleTap(let k): return "双击 \(k.symbol)"
        case .combo(let c): return c.display
        case .off: return "未设置"
        }
    }
}

public enum ShelfEdge: String, Codable, CaseIterable { case left, right, off }

/// 舞台模式时桌面怎么盖：毛玻璃（干净）/ 透出壁纸（好看）。两种都会挡住对桌面的点击，防止「点按墙纸显示桌面」把窗口推开
public enum CurtainLook: String, Codable, CaseIterable { case glass, wallpaper }

/// 用户偏好。存 settings.json；新增字段都有默认值，旧文件可直接读。
/// 数字槽位用哪个修饰键：修饰键+数字 = 跳到那个窗口，修饰键+⇧+数字 = 把当前窗口钉到那里
public enum SlotModifier: String, Codable, CaseIterable {
    case option, control, controlOption, off

    public var symbol: String {
        switch self {
        case .option: return "⌥"
        case .control: return "⌃"
        case .controlOption: return "⌃⌥"
        case .off: return ""
        }
    }

    public var carbon: UInt32 {
        switch self {
        case .option: return KeyCombo.option
        case .control: return KeyCombo.control
        case .controlOption: return KeyCombo.control | KeyCombo.option
        case .off: return 0
        }
    }

    public var note: String {
        switch self {
        case .option: return "最顺手。代价：⌥+数字原本输入的 ¡™£¢∞§¶•ª 这些符号打不出来了"
        case .control: return "不占用任何符号；少数终端 / 游戏里 ⌃数字有自己的用途"
        case .controlOption: return "几乎不会冲突，但要按两个键"
        case .off: return "不用数字槽位"
        }
    }
}

public struct WeftSettings: Codable, Equatable {
    public var setupDone = false
    /// 总控
    public var hubTrigger: Trigger = .doubleTap(.rightOption)
    /// 快速切换（按住修饰键连按）
    public var quickSwitch: Trigger = .combo(.optionTab)
    /// 舞台模式开关
    public var stageTrigger: Trigger = .doubleTap(.rightCommand)
    public var shelfEdge: ShelfEdge = .left
    /// 用快捷键打开侧栏（打开后按数字直达）
    public var shelfTrigger: Trigger = .doubleTap(.leftOption)
    /// 场景切换器（截图卡片左右滑）
    /// 默认不占键：⌃← / ⌃→ 第一下浮出来的就是同一排卡片。想要单独的键可以在设置里给它一个
    public var sceneTrigger: Trigger = .off
    /// 鼠标停在边缘多久才弹出
    public var shelfDelay: Double = 0.2
    /// 屏幕边上露一个小把手：鼠标滑上去 / 点一下打开侧栏（旁边紧挨着另一块屏、边缘碰不到时靠它）
    public var shelfHandle = true
    /// 把手在屏幕边上的高度（0 = 最上，1 = 最下），可以上下拖
    public var shelfHandleY: Double = 0.5
    /// 舞台窗口之间的间隙
    public var stageGap: Double = 10
    /// 舞台模式时用毛玻璃盖住桌面图标
    public var stageCurtain = true
    /// 幕布的样子
    public var curtainLook: CurtainLook = .glass
    /// 舞台模式下，你用 ⌘Tab / 点 Dock 切到的窗口自动上台
    public var stageAutoPromote = true
    /// 数字槽位的修饰键
    /// 默认关：⌥+数字会占掉 ¡™£¢∞ 这些符号，而且又是 18 个要记的键。想用的人在设置里打开
    public var slotModifier: SlotModifier = .off
    /// 舞台模式下，⌃← / ⌃→ 和四指左右滑切换场景（像切系统桌面一样）
    public var sceneSwipe = true
    /// 随手窗口：这些 App 的窗口不进场景、不占格子、切场景时不藏，原样浮在上面（访达、预览这类随开随关的）
    public var floatingApps: [String] = []

    public init() {}

    enum CodingKeys: String, CodingKey {
        case setupDone, hubTrigger, quickSwitch, stageTrigger, shelfEdge, shelfTrigger, sceneTrigger, shelfDelay, shelfHandle, shelfHandleY, stageGap, stageCurtain, curtainLook, stageAutoPromote, slotModifier, sceneSwipe, floatingApps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = WeftSettings()
        setupDone = (try? c.decode(Bool.self, forKey: .setupDone)) ?? d.setupDone
        hubTrigger = (try? c.decode(Trigger.self, forKey: .hubTrigger)) ?? d.hubTrigger
        quickSwitch = (try? c.decode(Trigger.self, forKey: .quickSwitch)) ?? d.quickSwitch
        stageTrigger = (try? c.decode(Trigger.self, forKey: .stageTrigger)) ?? d.stageTrigger
        shelfEdge = (try? c.decode(ShelfEdge.self, forKey: .shelfEdge)) ?? d.shelfEdge
        shelfTrigger = (try? c.decode(Trigger.self, forKey: .shelfTrigger)) ?? d.shelfTrigger
        sceneTrigger = (try? c.decode(Trigger.self, forKey: .sceneTrigger)) ?? d.sceneTrigger
        shelfDelay = (try? c.decode(Double.self, forKey: .shelfDelay)) ?? d.shelfDelay
        shelfHandle = (try? c.decode(Bool.self, forKey: .shelfHandle)) ?? d.shelfHandle
        shelfHandleY = (try? c.decode(Double.self, forKey: .shelfHandleY)) ?? d.shelfHandleY
        stageGap = (try? c.decode(Double.self, forKey: .stageGap)) ?? d.stageGap
        stageCurtain = (try? c.decode(Bool.self, forKey: .stageCurtain)) ?? d.stageCurtain
        curtainLook = (try? c.decode(CurtainLook.self, forKey: .curtainLook)) ?? d.curtainLook
        stageAutoPromote = (try? c.decode(Bool.self, forKey: .stageAutoPromote)) ?? d.stageAutoPromote
        slotModifier = (try? c.decode(SlotModifier.self, forKey: .slotModifier)) ?? d.slotModifier
        sceneSwipe = (try? c.decode(Bool.self, forKey: .sceneSwipe)) ?? d.sceneSwipe
        floatingApps = (try? c.decode([String].self, forKey: .floatingApps)) ?? d.floatingApps
    }

    public static func load(_ store: Store = .shared) -> WeftSettings { store.load(WeftSettings.self, "settings.json") ?? WeftSettings() }
    public func save(_ store: Store = .shared) { store.save(self, "settings.json") }

    /// 精简键位：只留舞台、快速切换、⌃←/→ 三样要记的，侧栏的键留给爱用键盘的人；场景切换器和数字槽位不占键
    public mutating func simplifyKeys() {
        let d = WeftSettings()
        sceneTrigger = d.sceneTrigger
        slotModifier = d.slotModifier
        sceneSwipe = true
    }

    /// 同一个触发方式不能给两个功能用
    public func conflicts() -> [String] {
        let all: [(String, Trigger)] = [("总控", hubTrigger), ("快速切换", quickSwitch), ("舞台模式", stageTrigger), ("侧栏", shelfTrigger), ("场景切换", sceneTrigger)]
        var out: [String] = []
        for i in all.indices { for j in all.indices where j > i && all[i].1 != .off && all[i].1 == all[j].1 {
            out.append("「\(all[i].0)」和「\(all[j].0)」都用了 \(all[i].1.display)")
        } }
        return out
    }
}
