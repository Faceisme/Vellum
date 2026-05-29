import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ClipboardPanelController {
    private let monitor: ClipboardMonitor
    private let onShowSettings: @MainActor () -> Void
    private var panel: VellumPanel?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?

    /// 面板弹出前的前台 App，用于“直接粘贴到当前 App”
    private var previousApp: NSRunningApplication?

    init(monitor: ClipboardMonitor, onShowSettings: @escaping @MainActor () -> Void) {
        self.monitor = monitor
        self.onShowSettings = onShowSettings
    }

    func toggle() {
        if panel?.isVisible == true {
            hide()
        } else {
            show()
        }
    }

    func show() {
        // 记录“当前正在用的 App”，必须在激活自己之前抓
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        let finalFrame = frameForPanel()
        var startFrame = finalFrame
        startFrame.origin.y -= 28

        panel.setFrame(startFrame, display: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitors()

        // Paste 风格的底部浮现：稍慢一点，减少顿挫感。
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.38
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.22, 1.0)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }

        removeEventMonitors()

        var targetFrame = panel.frame
        targetFrame.origin.y -= 24

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.0, 0.68, 1.0)
            panel.animator().setFrame(targetFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                panel.orderOut(nil)
            }
        }
    }

    // MARK: - 选中卡片：复制（+ 可选直接粘贴）

    private func handleSelect(_ item: ClipboardItem) {
        monitor.restore(item)

        let shouldPaste = AppSettings.shared.pasteToActiveApp
        let target = previousApp

        hide()

        guard shouldPaste else { return }
        pasteIntoPreviousApp(target)
    }

    private func pasteIntoPreviousApp(_ target: NSRunningApplication?) {
        guard let target, target.bundleIdentifier != Bundle.main.bundleIdentifier else { return }

        // 没有辅助功能权限就只复制不粘贴（内容已在剪贴板，可手动 ⌘V）
        guard AccessibilityHelper.isTrusted else {
            AccessibilityHelper.promptForAccess()
            return
        }

        target.activate()

        // 等面板关闭、目标 App 拿到焦点后再模拟 ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            Self.postCommandV()
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func makePanel() -> VellumPanel {
        let content = ClipboardPanelView(
            monitor: monitor,
            onSelect: { [weak self] item in
                self?.handleSelect(item)
            },
            onClear: { [weak self] in
                self?.monitor.clear()
            },
            onSettings: { [weak self] in
                self?.onShowSettings()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )

        let panel = VellumPanel(
            contentRect: frameForPanel(),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: content)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func frameForPanel() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(screenFrame.width - 12, 2048)
        let height: CGFloat = 330
        let x = screenFrame.midX - width / 2
        let y = screenFrame.minY
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private func installEventMonitors() {
        removeEventMonitors()

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }

            if event.type == .leftMouseDown {
                if self.isCollapsedSearchHit(event) {
                    NotificationCenter.default.post(name: .vellumNavStartSearch, object: nil)
                }

                if !self.isTextInputHit(event) {
                    NotificationCenter.default.post(
                        name: .vellumNavCancelSearch,
                        object: nil,
                        userInfo: self.panelClickUserInfo(for: event)
                    )
                }
                return event
            }

            if self.isTextEditing(event) {
                if event.keyCode == 53 {
                    NotificationCenter.default.post(name: .vellumNavEscape, object: nil)
                    return nil
                }
                return event
            }

            if AppSettings.shared.previousItemShortcut?.matches(event) == true {
                NotificationCenter.default.post(name: .vellumNavLeft, object: nil)
                return nil
            }

            if AppSettings.shared.nextItemShortcut?.matches(event) == true {
                NotificationCenter.default.post(name: .vellumNavRight, object: nil)
                return nil
            }

            switch event.keyCode {
            case 53:
                self.hide()
                return nil
            case 51, 117:
                NotificationCenter.default.post(name: .vellumNavDelete, object: nil)
                return nil
            case 123:
                NotificationCenter.default.post(name: .vellumNavLeft, object: nil)
                return nil
            case 124:
                NotificationCenter.default.post(name: .vellumNavRight, object: nil)
                return nil
            case 36, 76:
                NotificationCenter.default.post(name: .vellumNavSelect, object: nil)
                return nil
            default:
                return event
            }
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.hide()
            }
        }
    }

    private func removeEventMonitors() {
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
        }
        localKeyMonitor = nil
        globalMouseMonitor = nil
    }

    private func isTextEditing(_ event: NSEvent) -> Bool {
        guard let responder = event.window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField { return true }

        let typeName = String(describing: type(of: responder))
        return typeName.contains("FieldEditor") || typeName.contains("Text")
    }

    private func isTextInputHit(_ event: NSEvent) -> Bool {
        guard
            let window = event.window,
            let contentView = window.contentView
        else {
            return false
        }

        let point = contentView.convert(event.locationInWindow, from: nil)
        var hitView: NSView? = contentView.hitTest(point)

        while let view = hitView {
            if view is NSTextView || view is NSTextField {
                return true
            }

            let typeName = String(describing: type(of: view))
            if typeName.contains("TextField") || typeName.contains("TextView") || typeName.contains("FieldEditor") {
                return true
            }

            hitView = view.superview
        }

        return false
    }

    private func panelClickUserInfo(for event: NSEvent) -> [String: CGFloat] {
        guard let contentView = event.window?.contentView else { return [:] }

        let bounds = contentView.bounds
        return [
            "x": event.locationInWindow.x,
            "y": event.locationInWindow.y,
            "width": bounds.width,
            "height": bounds.height
        ]
    }

    private func isCollapsedSearchHit(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }

        let bounds = contentView.bounds
        let point = event.locationInWindow
        let toolbarMinY = bounds.maxY - 68
        let toolbarMaxY = bounds.maxY - 14
        let searchCenterX = bounds.midX - 92
        let searchHalfWidth: CGFloat = 30

        return point.y >= toolbarMinY
            && point.y <= toolbarMaxY
            && abs(point.x - searchCenterX) <= searchHalfWidth
    }
}

final class VellumPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
