import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let clipboardMonitor = ClipboardMonitor()
    private lazy var panelController = ClipboardPanelController(
        monitor: clipboardMonitor,
        onShowSettings: { [weak self] in
            self?.showSettings()
        }
    )
    private var settingsController: SettingsWindowController?
    private var hotKeyManager: HotKeyManager?
    private var statusItem: NSStatusItem?
    private var settingsCancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKeyManager = HotKeyManager {
            self.panelController.toggle()
        }
        configureHotKey(showAlertOnFailure: true)

        bindSettings()
        applyStatusItemVisibility()
        clipboardMonitor.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.panelController.prepare()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出前强制落盘并等待写盘完成，避免丢失未保存的历史
        clipboardMonitor.flushAndWait()
    }

    private func bindSettings() {
        AppSettings.shared.$hideMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.applyStatusItemVisibility()
                }
            }
            .store(in: &settingsCancellables)

        AppSettings.shared.$launchShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.configureHotKey(showAlertOnFailure: true)
                }
            }
            .store(in: &settingsCancellables)
    }

    private func configureHotKey(showAlertOnFailure: Bool) {
        let shortcut = AppSettings.shared.launchShortcut
        let registered = hotKeyManager?.updateShortcut(shortcut) ?? false
        if showAlertOnFailure, shortcut != nil, !registered {
            showHotKeyFailureAlert(shortcut: shortcut)
        }
    }

    private func applyStatusItemVisibility() {
        if AppSettings.shared.hideMenuBarIcon {
            removeStatusItem()
        } else {
            configureStatusItem()
        }
    }

    private func configureStatusItem() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Vellum")
        item.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(menuItem("显示剪贴板", action: #selector(showClipboardPanel), key: ""))
        menu.addItem(menuItem("偏好设置...", action: #selector(showSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("隐藏菜单栏图标", action: #selector(hideMenuBarIcon), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("清空历史", action: #selector(clearHistory), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 Vellum", action: #selector(quit), key: "q"))
        item.menu = menu

        statusItem = item
    }

    private func removeStatusItem() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
    }

    private func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showClipboardPanel() {
        panelController.show()
    }

    @objc private func showSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController(monitor: clipboardMonitor)
        }
        settingsController?.show()
    }

    @objc private func clearHistory() {
        clipboardMonitor.clear()
    }

    @objc private func hideMenuBarIcon() {
        AppSettings.shared.hideMenuBarIcon = true
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showHotKeyFailureAlert(shortcut: VellumKeyboardShortcut?) {
        let alert = NSAlert()
        alert.messageText = "快捷键注册失败"
        let shortcutText = shortcut?.displayString ?? "当前快捷键"
        alert.informativeText = "\(shortcutText) 可能已被其他应用占用。你仍然可以从菜单栏打开 Vellum，或在设置中换一个快捷键。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}
