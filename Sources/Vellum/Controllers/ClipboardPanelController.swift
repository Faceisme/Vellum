import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class ClipboardPanelController {
    private enum PanelState {
        case hidden
        case showing
        case visible
        case hiding
    }

    private let monitor: ClipboardMonitor
    private let onShowSettings: @MainActor () -> Void
    private var panel: VellumPanel?
    private var localKeyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var didWarmPanel = false
    private var panelState: PanelState = .hidden
    private var animationToken = 0

    /// 面板弹出前的前台 App，用于“直接粘贴到当前 App”
    private var previousApp: NSRunningApplication?

    init(monitor: ClipboardMonitor, onShowSettings: @escaping @MainActor () -> Void) {
        self.monitor = monitor
        self.onShowSettings = onShowSettings
    }

    func prepare() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.setFrame(frameForPanel(), display: false)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()

        if !didWarmPanel {
            didWarmPanel = true
            warmPanelOffscreen(panel)
        }
    }

    func toggle() {
        switch panelState {
        case .hidden:
            show()
        case .hiding:
            show()
        case .showing, .visible:
            hide()
        }
    }

    func show() {
        guard panelState != .showing, panelState != .visible else { return }

        // 记录“当前正在用的 App”，必须在激活自己之前抓
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = frontmost
        }

        let panel = panel ?? makePanel()
        self.panel = panel

        let shouldContinueFromCurrentAnimation = panelState == .hiding && panel.isVisible
        animationToken += 1
        let token = animationToken
        panelState = .showing

        let finalFrame = frameForPanel()
        panel.setFrame(finalFrame, display: true)
        let start = prepareContentLayerForPresentation(
            panel,
            continuingCurrentAnimation: shouldContinueFromCurrentAnimation
        )
        panel.alphaValue = 1
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.displayIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        installEventMonitors()
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            self.animateContentLayerIn(
                panel,
                token: token,
                fromY: start.y,
                fromOpacity: start.opacity
            )
        }
    }

    func hide() {
        guard let panel, panel.isVisible, panelState != .hidden, panelState != .hiding else { return }

        animationToken += 1
        let token = animationToken
        panelState = .hiding

        removeEventMonitors()

        animateContentLayerOut(panel, token: token)
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
        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        // 关闭组透明度：弹出动画对整层做 opacity 渐变时，组透明度会把整棵图层树
        // （玻璃+卡片+阴影，约 1400×330 retina）每帧离屏重合成一次，是入场掉帧的主因。
        // 关掉后 opacity 按子图层各自应用，不再每帧离屏 flatten。
        hostingView.layer?.allowsGroupOpacity = false
        panel.contentView = hostingView
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // 阴影画在内容层里，跟随底部弹出动画一起移动
        panel.animationBehavior = .none
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

    private func warmPanelOffscreen(_ panel: VellumPanel) {
        let finalFrame = frameForPanel()
        let warmFrame = finalFrame.offsetBy(dx: 0, dy: -finalFrame.height - 180)

        panel.alphaValue = 0
        panel.setFrame(warmFrame, display: false)
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()

        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.alphaValue == 0 else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(finalFrame, display: false)
        }
    }

    private var panelSlideYOffset: CGFloat {
        -56
    }

    private func prepareContentLayerForPresentation(
        _ panel: VellumPanel,
        continuingCurrentAnimation: Bool
    ) -> (y: CGFloat, opacity: Float) {
        guard let contentView = panel.contentView, let layer = contentView.layer else {
            return (panelSlideYOffset, 0)
        }

        let presentation = layer.presentation()
        let startY = continuingCurrentAnimation
            ? CGFloat(presentation?.transform.m42 ?? layer.transform.m42)
            : panelSlideYOffset
        let startOpacity = continuingCurrentAnimation
            ? (presentation?.opacity ?? layer.opacity)
            : 0

        contentView.wantsLayer = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = startOpacity
        layer.transform = CATransform3DMakeTranslation(0, startY, 0)
        CATransaction.commit()

        return (startY, startOpacity)
    }

    private func animateContentLayerIn(
        _ panel: VellumPanel,
        token: Int,
        fromY: CGFloat,
        fromOpacity: Float
    ) {
        guard let layer = panel.contentView?.layer else { return }

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = fromY
        move.toValue = 0

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 1

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.88, 0.20, 1.0)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel, weak layer] in
            Task { @MainActor in
                guard let self, let panel, let layer else { return }
                guard self.animationToken == token, self.panelState == .showing else { return }
                layer.removeAllAnimations()
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                self.panelState = panel.isVisible ? .visible : .hidden
                if panel.isVisible {
                    NotificationCenter.default.post(name: .vellumNavWarmSearch, object: nil)
                }
            }
        }
        CATransaction.setDisableActions(true)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        layer.add(group, forKey: "vellumPanelIn")
        CATransaction.commit()
    }

    private func animateContentLayerOut(_ panel: VellumPanel, token: Int) {
        guard let contentView = panel.contentView, let layer = contentView.layer else {
            panelState = .hidden
            panel.orderOut(nil)
            return
        }

        let offset = panelSlideYOffset
        let presentation = layer.presentation()
        let startY = CGFloat(presentation?.transform.m42 ?? layer.transform.m42)
        let startOpacity = presentation?.opacity ?? layer.opacity

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak panel, weak layer] in
            Task { @MainActor in
                guard let self, let panel, let layer else { return }
                guard self.animationToken == token, self.panelState == .hiding else { return }
                panel.orderOut(nil)
                layer.removeAllAnimations()
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                self.panelState = .hidden
            }
        }

        let move = CABasicAnimation(keyPath: "transform.translation.y")
        move.fromValue = startY
        move.toValue = offset

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = startOpacity
        fade.toValue = 0

        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.22
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.opacity = 0
        layer.transform = CATransform3DMakeTranslation(0, offset, 0)
        layer.add(group, forKey: "vellumPanelOut")
        CATransaction.commit()
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
