import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限：模拟 ⌘V 必需。
enum AccessibilityHelper {
    /// 当前是否已被信任
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// 触发系统授权提示，并把本 App 注册进“辅助功能”列表。返回当前是否已信任。
    @discardableResult
    static func promptForAccess() -> Bool {
        // 直接用字符串字面量，避免不同 SDK 下常量导入形式差异
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 打开 系统设置 ▸ 隐私与安全性 ▸ 辅助功能
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
