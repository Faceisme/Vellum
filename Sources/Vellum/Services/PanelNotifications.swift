import Foundation

/// 面板内部键盘导航通知（控制器 → 视图，解耦 SwiftUI 焦点系统的限制）
extension Notification.Name {
    static let vellumNavLeft   = Notification.Name("vellum.nav.left")
    static let vellumNavRight  = Notification.Name("vellum.nav.right")
    static let vellumNavDelete = Notification.Name("vellum.nav.delete")
    static let vellumNavSelect = Notification.Name("vellum.nav.select")
    static let vellumNavEscape = Notification.Name("vellum.nav.escape")
    static let vellumNavScroll = Notification.Name("vellum.nav.scroll")
    static let vellumNavStartSearch = Notification.Name("vellum.nav.startSearch")
    static let vellumNavCancelSearch = Notification.Name("vellum.nav.cancelSearch")
    static let vellumPanelResetSearch = Notification.Name("vellum.panel.resetSearch")
}
