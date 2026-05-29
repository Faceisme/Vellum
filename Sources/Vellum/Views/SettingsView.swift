import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case shortcuts = "键盘快捷键"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .shortcuts: "keyboard"
        }
    }
}

struct SettingsView: View {
    var onClearHistory: () -> Void = {}

    @ObservedObject private var settings = AppSettings.shared
    @State private var selected: SettingsSection = .general

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            HStack(spacing: 0) {
                sidebar
                    .padding(.leading, 14)
                    .padding(.vertical, 18)

                Spacer()
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 20) {
                    Text(selected.rawValue)
                        .font(.system(size: 23, weight: .bold))
                        .padding(.top, 52)

                    content
                }
                .padding(.trailing, 28)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 720, height: 700)
    }

    private var sidebar: some View {
        ZStack {
            GlassEffectView(
                cornerRadius: 28,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.74),
                style: .regular
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.28),
                        Color(nsColor: .controlColor).opacity(0.18),
                        Color.white.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(.white.opacity(0.34), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.08), radius: 20, x: 0, y: 8)
            .shadow(color: .black.opacity(0.04), radius: 5, x: 1, y: 1)

            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                    .frame(height: 84)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SettingsSection.allCases) { section in
                        SidebarItem(
                            title: section.rawValue,
                            symbolName: section.symbolName,
                            isSelected: selected == section
                        ) {
                            selected = section
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 10)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        switch selected {
        case .general:
            generalContent
        case .shortcuts:
            shortcutContent
        }
    }

    private var retentionDescription: String {
        switch settings.retentionIndex {
        case 0: "保留最近 1 天的历史"
        case 1: "保留最近 1 周的历史"
        case 2: "保留最近 1 个月的历史"
        case 3: "保留最近 1 年的历史"
        default: "永久保留历史"
        }
    }

    private func confirmClearHistory() {
        let alert = NSAlert()
        alert.messageText = "删除所有剪贴板历史？"
        alert.informativeText = "此操作不可撤销（收藏项也会一并删除）。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            onClearHistory()
        }
    }

    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsCard {
                ToggleRow(title: "登录时打开", isOn: $settings.openAtLogin)
                ThinDivider()
                ToggleRow(
                    title: "隐藏菜单栏图标",
                    trailing: "仍可用 \(settings.launchShortcut?.displayString ?? "菜单栏") 呼出",
                    isOn: $settings.hideMenuBarIcon
                )
                ThinDivider()
                ToggleRow(title: "本地历史记录", trailing: "仅保存在这台 Mac", isOn: .constant(true))
                ThinDivider()
                ToggleRow(title: "音效", isOn: $settings.soundEnabled)
            }

            SettingsGroupTitle("粘贴项目")

            SettingsCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 16) {
                        RadioRow(
                            title: "到当前活动应用",
                            subtitle: "将选定的项目直接粘贴到您当前正在使用的应用程序中。",
                            isSelected: settings.pasteToActiveApp
                        ) {
                            settings.pasteToActiveApp = true
                        }

                        RadioRow(
                            title: "到剪贴板",
                            subtitle: "将选定的项目复制到系统剪贴板，以便稍后手动粘贴。",
                            isSelected: !settings.pasteToActiveApp
                        ) {
                            settings.pasteToActiveApp = false
                        }
                    }

                    Spacer(minLength: 12)

                    PasteIllustration()
                        .frame(width: 168, height: 108)
                        .padding(.top, 2)
                }
                .padding(.vertical, 6)

                ThinDivider()

                CheckboxRow(title: "始终以纯文本粘贴", isOn: $settings.alwaysPlainText)
            }

            SettingsGroupTitle("保留历史")

            SettingsCard {
                VStack(spacing: 14) {
                    Slider(
                        value: Binding(
                            get: { Double(settings.retentionIndex) },
                            set: { settings.retentionIndex = Int($0.rounded()) }
                        ),
                        in: 0...4,
                        step: 1
                    )
                    .tint(.blue)
                    .padding(.top, 6)

                    HStack {
                        Text("天")
                        Spacer()
                        Text("周")
                        Spacer()
                        Text("个月")
                        Spacer()
                        Text("年")
                        Spacer()
                        Text("永久")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                    ThinDivider()

                    HStack {
                        Text(retentionDescription)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("删除历史…", role: .destructive) {
                            confirmClearHistory()
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var shortcutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard {
                EditableShortcutRow(
                    title: "启动 Vellum",
                    shortcut: $settings.launchShortcut,
                    clearable: true,
                    requiresModifier: true
                )
                ThinDivider()
                EditableShortcutRow(
                    title: "启动 Vellum Stack",
                    shortcut: $settings.stackShortcut,
                    clearable: true,
                    requiresModifier: true
                )
            }

            SettingsCard {
                EditableShortcutRow(
                    title: "显示下一个项目",
                    shortcut: $settings.nextItemShortcut,
                    clearable: true,
                    requiresModifier: false
                )
                ThinDivider()
                EditableShortcutRow(
                    title: "显示上一个项目",
                    shortcut: $settings.previousItemShortcut,
                    clearable: true,
                    requiresModifier: false
                )
            }

            SettingsCard {
                ModifierRow(title: "快速粘贴", selection: $settings.quickPasteModifier, suffix: "+  1…9")
                ThinDivider()
                ModifierRow(title: "纯文本模式", selection: $settings.plainTextModifier, suffix: nil)
            }

            HStack {
                Spacer()
                Button("将快捷方式重置为默认…") {
                    settings.launchShortcut = .defaultLaunch
                    settings.stackShortcut = nil
                    settings.nextItemShortcut = nil
                    settings.previousItemShortcut = nil
                    settings.quickPasteModifier = .command
                    settings.plainTextModifier = .shift
                }
                    .buttonStyle(.bordered)
            }
        }
    }

}

private struct SidebarItem: View {
    let title: String
    let symbolName: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbolName)
                    .font(.system(size: 16, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(foregroundStyle)
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedBackground)
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(.white.opacity(isWindowActive ? 0.24 : 0.12), lineWidth: 0.7)
                        }
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlColor).opacity(0.26))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.22, dampingFraction: 0.86), value: isHovered)
        .animation(.spring(response: 0.24, dampingFraction: 0.88), value: isSelected)
    }

    private var isWindowActive: Bool {
        controlActiveState == .key
    }

    private var foregroundStyle: Color {
        if isSelected {
            return isWindowActive ? .white : Color(nsColor: .labelColor).opacity(0.36)
        }
        return isWindowActive ? Color(nsColor: .labelColor).opacity(0.94) : Color(nsColor: .labelColor).opacity(0.30)
    }

    private var selectedBackground: Color {
        isWindowActive ? .blue : Color(nsColor: .controlColor).opacity(0.56)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.6)
        }
    }
}

private struct SettingsGroupTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .padding(.leading, 4)
            .padding(.top, 2)
    }
}

private struct ToggleRow: View {
    let title: String
    var trailing: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
        .frame(height: 36)
    }
}

private struct RadioRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                ZStack {
                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 16, height: 16)
                        Circle()
                            .fill(.white)
                            .frame(width: 5, height: 5)
                    } else {
                        Circle()
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5)
                            .frame(width: 16, height: 16)
                    }
                }
                .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CheckboxRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isOn ? Color.blue : Color(nsColor: .controlColor))
                    .frame(width: 16, height: 16)
                    .overlay {
                        if isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        }
                    }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer()
            }
            .frame(height: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EditableShortcutRow: View {
    let title: String
    @Binding var shortcut: VellumKeyboardShortcut?
    var clearable: Bool
    var requiresModifier: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            ShortcutRecorderButton(
                shortcut: $shortcut,
                clearable: clearable,
                requiresModifier: requiresModifier
            )
        }
        .frame(height: 44)
    }
}

private struct ShortcutRecorderButton: View {
    @Binding var shortcut: VellumKeyboardShortcut?
    var clearable: Bool
    var requiresModifier: Bool

    @State private var isRecording = false
    @State private var validationMessage: String?
    @State private var keyMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                startRecording()
            } label: {
                HStack(spacing: 8) {
                    Text(displayText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isRecording ? Color.blue : Color(nsColor: .labelColor))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)

                    if isRecording {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 11)
                .frame(width: 158, height: 28)
                .background(fieldBackground, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(
                            isRecording ? Color.blue.opacity(0.72) : Color(nsColor: .separatorColor),
                            lineWidth: isRecording ? 1.2 : 0.8
                        )
                }
            }
            .buttonStyle(.plain)

            if clearable {
                Button {
                    shortcut = nil
                    stopRecording()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 28)
                }
                .buttonStyle(.plain)
                .opacity(shortcut == nil ? 0.35 : 1)
            }
        }
        .onDisappear {
            stopRecording()
        }
    }

    private var displayText: String {
        if let validationMessage {
            return validationMessage
        }
        if isRecording {
            return "输入快捷键"
        }
        return shortcut?.displayString ?? "无"
    }

    private var fieldBackground: Color {
        if isRecording {
            return Color.blue.opacity(0.10)
        }
        return Color(nsColor: .textBackgroundColor).opacity(0.8)
    }

    private func startRecording() {
        validationMessage = nil
        isRecording = true
        installMonitor()
    }

    private func installMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        let candidate = VellumKeyboardShortcut(event: event)
        if requiresModifier && !candidate.hasModifier {
            validationMessage = "需要组合键"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                if isRecording {
                    validationMessage = nil
                }
            }
            return
        }

        shortcut = candidate
        stopRecording()
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        isRecording = false
        validationMessage = nil
    }
}

private struct ModifierRow: View {
    let title: String
    @Binding var selection: VellumModifierKey
    var suffix: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Menu {
                ForEach(VellumModifierKey.allCases) { key in
                    Button(key.displayName) {
                        selection = key
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(selection.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            if let suffix {
                Text(suffix)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
        }
        .frame(height: 44)
    }
}

private struct ShortcutRow: View {
    let title: String
    let shortcut: String
    var clearable: Bool = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            HStack(spacing: 0) {
                Spacer()
                Text(shortcut)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if clearable {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 11)
            .frame(width: 152, height: 28)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.8), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.8)
            }
        }
        .frame(height: 44)
    }
}

private struct StepperRow: View {
    let title: String
    let value: String
    var suffix: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            HStack(spacing: 6) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            if let suffix {
                Text(suffix)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 10)
            }
        }
        .frame(height: 44)
    }
}

private struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.5))
            .frame(height: 0.6)
    }
}

private struct PasteIllustration: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.orange.opacity(0.82), Color.orange.opacity(0.58), Color.red.opacity(0.72)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.white.opacity(0.78))
                .frame(width: 68, height: 64)
                .offset(x: 10, y: -6)

            VStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.orange.opacity(0.28))
                        .frame(width: 42, height: 3)
                }
            }
            .offset(x: 10, y: -7)

            HStack(spacing: 5) {
                ForEach(0..<5, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.white.opacity(0.42))
                        .frame(width: 20, height: 24)
                }
            }
            .offset(y: 30)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.black.opacity(0.72))
                .offset(x: -36, y: -6)
        }
    }
}
