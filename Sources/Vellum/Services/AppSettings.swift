import AppKit
import Foundation
import ServiceManagement

/// 轻量设置存储（UserDefaults 持久化）。仅在主线程读写。
final class AppSettings: ObservableObject, @unchecked Sendable {
    static let shared = AppSettings()

    /// 点击卡片后：true = 直接粘贴到当前活动 App；false = 仅复制回剪贴板
    @Published var pasteToActiveApp: Bool {
        didSet { defaults.set(pasteToActiveApp, forKey: Keys.pasteToActiveApp) }
    }

    /// 始终以纯文本粘贴
    @Published var alwaysPlainText: Bool {
        didSet { defaults.set(alwaysPlainText, forKey: Keys.alwaysPlainText) }
    }

    /// 登录时自动启动（用 SMAppService 注册登录项）
    @Published var openAtLogin: Bool {
        didSet { applyLoginItem() }
    }

    /// 隐藏菜单栏图标；隐藏后仍可通过快捷键呼出面板。
    @Published var hideMenuBarIcon: Bool {
        didSet { defaults.set(hideMenuBarIcon, forKey: Keys.hideMenuBarIcon) }
    }

    /// 呼出主面板的全局快捷键；nil 表示禁用。
    @Published var launchShortcut: VellumKeyboardShortcut? {
        didSet { saveShortcut(launchShortcut, keyPrefix: Keys.launchShortcutPrefix) }
    }

    /// 预留：Vellum Stack 快捷键。
    @Published var stackShortcut: VellumKeyboardShortcut? {
        didSet { saveShortcut(stackShortcut, keyPrefix: Keys.stackShortcutPrefix) }
    }

    /// 面板内显示下一个项目。
    @Published var nextItemShortcut: VellumKeyboardShortcut? {
        didSet { saveShortcut(nextItemShortcut, keyPrefix: Keys.nextItemShortcutPrefix) }
    }

    /// 面板内显示上一个项目。
    @Published var previousItemShortcut: VellumKeyboardShortcut? {
        didSet { saveShortcut(previousItemShortcut, keyPrefix: Keys.previousItemShortcutPrefix) }
    }

    /// 快速粘贴使用的修饰键。
    @Published var quickPasteModifier: VellumModifierKey {
        didSet { defaults.set(quickPasteModifier.rawValue, forKey: Keys.quickPasteModifier) }
    }

    /// 纯文本模式使用的修饰键。
    @Published var plainTextModifier: VellumModifierKey {
        didSet { defaults.set(plainTextModifier.rawValue, forKey: Keys.plainTextModifier) }
    }

    /// 复制/粘贴时播放音效
    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// 历史保留档位：0=天 1=周 2=个月 3=年 4=永久
    @Published var retentionIndex: Int {
        didSet { defaults.set(retentionIndex, forKey: Keys.retentionIndex) }
    }

    /// 保留时长（秒）；nil = 永久
    var retentionInterval: TimeInterval? {
        switch retentionIndex {
        case 0: return 86_400            // 1 天
        case 1: return 86_400 * 7        // 1 周
        case 2: return 86_400 * 30       // 1 个月
        case 3: return 86_400 * 365      // 1 年
        default: return nil              // 永久
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pasteToActiveApp = "vellum.pasteToActiveApp"
        static let alwaysPlainText = "vellum.alwaysPlainText"
        static let retentionIndex = "vellum.retentionIndex"
        static let soundEnabled = "vellum.soundEnabled"
        static let hideMenuBarIcon = "vellum.hideMenuBarIcon"
        static let launchShortcutPrefix = "vellum.shortcut.launch"
        static let stackShortcutPrefix = "vellum.shortcut.stack"
        static let nextItemShortcutPrefix = "vellum.shortcut.nextItem"
        static let previousItemShortcutPrefix = "vellum.shortcut.previousItem"
        static let quickPasteModifier = "vellum.shortcut.quickPasteModifier"
        static let plainTextModifier = "vellum.shortcut.plainTextModifier"
    }

    private init() {
        defaults.register(defaults: [
            Keys.pasteToActiveApp: true,
            Keys.retentionIndex: 2,
            Keys.hideMenuBarIcon: false,
            "\(Keys.launchShortcutPrefix).enabled": true,
            "\(Keys.launchShortcutPrefix).keyCode": Int(VellumKeyboardShortcut.defaultLaunch.keyCode),
            "\(Keys.launchShortcutPrefix).modifiers": Int(VellumKeyboardShortcut.defaultLaunch.modifiers.rawValue),
            Keys.quickPasteModifier: VellumModifierKey.command.rawValue,
            Keys.plainTextModifier: VellumModifierKey.shift.rawValue
        ])
        pasteToActiveApp = defaults.bool(forKey: Keys.pasteToActiveApp)
        alwaysPlainText = defaults.bool(forKey: Keys.alwaysPlainText)
        retentionIndex = defaults.integer(forKey: Keys.retentionIndex)
        soundEnabled = defaults.bool(forKey: Keys.soundEnabled)
        hideMenuBarIcon = defaults.bool(forKey: Keys.hideMenuBarIcon)
        launchShortcut = Self.loadShortcut(from: defaults, keyPrefix: Keys.launchShortcutPrefix)
        stackShortcut = Self.loadShortcut(from: defaults, keyPrefix: Keys.stackShortcutPrefix)
        nextItemShortcut = Self.loadShortcut(from: defaults, keyPrefix: Keys.nextItemShortcutPrefix)
        previousItemShortcut = Self.loadShortcut(from: defaults, keyPrefix: Keys.previousItemShortcutPrefix)
        quickPasteModifier = VellumModifierKey(rawValue: defaults.string(forKey: Keys.quickPasteModifier) ?? "") ?? .command
        plainTextModifier = VellumModifierKey(rawValue: defaults.string(forKey: Keys.plainTextModifier) ?? "") ?? .shift
        // 登录项以系统状态为准（didSet 不会在 init 阶段触发）
        openAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    private static func loadShortcut(from defaults: UserDefaults, keyPrefix: String) -> VellumKeyboardShortcut? {
        let enabledKey = "\(keyPrefix).enabled"
        guard defaults.bool(forKey: enabledKey) else { return nil }

        let keyCode = defaults.integer(forKey: "\(keyPrefix).keyCode")
        let modifiers = defaults.integer(forKey: "\(keyPrefix).modifiers")
        return VellumKeyboardShortcut(
            keyCode: UInt32(keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        )
    }

    private func saveShortcut(_ shortcut: VellumKeyboardShortcut?, keyPrefix: String) {
        let enabledKey = "\(keyPrefix).enabled"
        guard let shortcut else {
            defaults.set(false, forKey: enabledKey)
            return
        }

        defaults.set(true, forKey: enabledKey)
        defaults.set(Int(shortcut.keyCode), forKey: "\(keyPrefix).keyCode")
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: "\(keyPrefix).modifiers")
    }

    private func applyLoginItem() {
        do {
            if openAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            NSLog("Vellum 登录项设置失败: \(error.localizedDescription)")
        }
    }
}
