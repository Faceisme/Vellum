import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let monitor: ClipboardMonitor

    init(monitor: ClipboardMonitor) {
        self.monitor = monitor
    }

    private lazy var window: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Vellum 设置"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor

        let rootView = SettingsView(onClearHistory: { [weak monitor] in
            monitor?.clear()
        })
        window.contentView = NSHostingView(rootView: rootView)
        window.center()
        positionWindowButtons(in: window)
        return window
    }()

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        positionWindowButtons(in: window)
    }

    private func positionWindowButtons(in window: NSWindow) {
        guard
            let closeButton = window.standardWindowButton(.closeButton),
            let minimizeButton = window.standardWindowButton(.miniaturizeButton),
            let zoomButton = window.standardWindowButton(.zoomButton)
        else { return }

        let leftInset: CGFloat = 30
        let spacing: CGFloat = 26
        let currentY = closeButton.frame.origin.y - 8

        closeButton.setFrameOrigin(NSPoint(x: leftInset, y: currentY))
        minimizeButton.setFrameOrigin(NSPoint(x: leftInset + spacing, y: currentY))
        zoomButton.setFrameOrigin(NSPoint(x: leftInset + spacing * 2, y: currentY))
    }
}
