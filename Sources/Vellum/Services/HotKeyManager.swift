import Carbon
import Foundation

@MainActor
final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let action: @MainActor () -> Void

    private(set) var isRegistered = false

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
        installHandler()
    }

    @discardableResult
    func updateShortcut(_ shortcut: VellumKeyboardShortcut?) -> Bool {
        unregisterShortcut()
        guard let shortcut else {
            isRegistered = false
            return true
        }

        guard eventHandler != nil else {
            isRegistered = false
            return false
        }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("VLLM"), id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        isRegistered = registerStatus == noErr
        return isRegistered
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    manager.action()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandler
        )

        guard handlerStatus == noErr else { return }
    }

    private func unregisterShortcut() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        isRegistered = false
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { result, character in
        (result << 8) + OSType(character)
    }
}
