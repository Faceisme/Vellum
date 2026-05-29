import AppKit
import SwiftUI

/// 工具栏搜索簇：磁贴样式的「剪贴板 / 收藏」筛选 + 可展开的搜索框。
///
/// 纯 SwiftUI 实现：展开/收起只靠 `isSearching` 的宽度状态切换 + 一次 `.animation`，
/// GPU 自己插值，没有手写 CALayer、没有 asyncAfter 收尾、没有重复触发。搜索框像画卷
/// 一样横向铺开，收起时缩回成一颗放大镜。展开后尾部带「清空」按钮与「按来源/类型过滤」菜单。
struct SearchToolbarClusterView: View {
    @Binding var isSearching: Bool
    @Binding var searchText: String
    @Binding var showFavoritesOnly: Bool
    @Binding var focusRequest: Int
    @Binding var resetRequest: Int
    @Binding var showFilterMenu: Bool
    @Binding var sourceFilter: String?
    @Binding var kindFilter: ClipboardKind?

    let availableKinds: [ClipboardKind]
    let availableSources: [ClipboardSourceOption]

    let onClipboardSelected: () -> Void
    let onFavoritesSelected: () -> Void
    let onSearchCancelled: () -> Void

    @FocusState private var isFieldFocused: Bool
    @State private var didWarmFieldEditor = false

    private enum Metric {
        static let height: CGFloat = 32
        static let collapsedSearch: CGFloat = 34
        static let expandedSearch: CGFloat = 392
        static let circleButton: CGFloat = 34
        static let spacing: CGFloat = 10
    }

    /// 无回弹的平滑曲线，比带弹性的 spring 更「丝滑」，贴合画卷横向铺开的观感。
    /// 时长在原 0.34 基础上提速约 30%（0.34 × 0.7 ≈ 0.24），手感更利落。
    private var expandAnimation: Animation {
        .smooth(duration: 0.24)
    }

    var body: some View {
        HStack(spacing: Metric.spacing) {
            searchCapsule

            if isSearching {
                circleButton(symbol: "clock.arrow.circlepath", help: "返回剪贴板") {
                    onSearchCancelled()
                }
                .transition(.opacity)
            } else {
                ToolbarPill(
                    title: "剪贴板",
                    symbol: "clock.arrow.circlepath",
                    isSelected: !showFavoritesOnly
                ) {
                    showFavoritesOnly = false
                    onClipboardSelected()
                }
                .transition(.opacity)
            }

            ToolbarPill(
                title: "收藏",
                symbol: "star.fill",
                isSelected: showFavoritesOnly
            ) {
                showFavoritesOnly = true
                onFavoritesSelected()
            }
        }
        .frame(height: 44)
        .animation(expandAnimation, value: isSearching)
        .onChange(of: isSearching) { _, expanded in
            // 文本框常驻视图树、field editor 也已离屏预热，这里直接聚焦即可，
            // 无需延迟，首次展开也不再为创建子树/编辑器掉帧。
            isFieldFocused = expanded
        }
        .onChange(of: focusRequest) { _, _ in
            // Cmd+F：仅在已展开时把焦点拉回搜索框；面板入场的「预热」请求不应自动展开。
            if isSearching { isFieldFocused = true }
        }
        .onChange(of: resetRequest) { _, _ in
            isFieldFocused = false
        }
        .onChange(of: showFilterMenu) { _, shown in
            // 过滤菜单关闭后把焦点交还搜索框，搜索会话延续；打开时弹层自然接管焦点。
            if !shown && isSearching { isFieldFocused = true }
        }
        .task {
            // 离屏预热：面板首次（在屏幕外）出现时，让常驻文本框静默拿一次焦点，
            // 创建窗口的 field editor。此刻文本框 opacity 0、宽度 0，不可见，
            // 因此用户「第一次」真正展开搜索时不再为此卡顿。
            guard !didWarmFieldEditor else { return }
            didWarmFieldEditor = true
            isFieldFocused = true
            try? await Task.sleep(nanoseconds: 60_000_000)
            if !isSearching { isFieldFocused = false }
        }
    }

    // MARK: - 搜索胶囊

    private var searchCapsule: some View {
        HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            // 文本框常驻：收起时压成 0 宽 + 透明，展开时铺满。避免首次插入子树的开销，
            // 它的出现也成为同一条宽度动画的一部分，更连贯。
            TextField("搜索", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .focused($isFieldFocused)
                .padding(.leading, 7)
                .frame(maxWidth: isSearching ? .infinity : 0, alignment: .leading)
                .opacity(isSearching ? 1 : 0)

            if isSearching {
                searchAccessories
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, isSearching ? 11 : 0)
        .frame(
            width: isSearching ? Metric.expandedSearch : Metric.collapsedSearch,
            height: Metric.height
        )
        .background {
            Capsule(style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(0.72))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            Color(nsColor: .controlAccentColor).opacity(isSearching ? 0.55 : 0),
                            lineWidth: 1.2
                        )
                }
        }
        .clipShape(Capsule(style: .continuous))
        .contentShape(Capsule(style: .continuous))
        .onTapGesture {
            if isSearching {
                isFieldFocused = true
            } else {
                isSearching = true
            }
        }
    }

    // MARK: - 搜索框尾部：清空 + 过滤菜单

    private var hasActiveFilter: Bool {
        sourceFilter != nil || kindFilter != nil
    }

    @ViewBuilder
    private var searchAccessories: some View {
        // 清空：仅在有输入时出现，点一下清空关键字并保持焦点
        if !searchText.isEmpty {
            Button {
                searchText = ""
                isFieldFocused = true
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .contentShape(Circle())
            }
            .buttonStyle(VellumPressButtonStyle(pressedScale: 0.84, pressedOpacity: 0.7))
            .help("清空")
            .padding(.trailing, 3)
        }

        // 按来源 / 类型过滤：再次 Cmd+F 或点此打开；有筛选生效时图标高亮
        Button {
            showFilterMenu.toggle()
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hasActiveFilter ? Color(nsColor: .controlAccentColor) : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.84, pressedOpacity: 0.7))
        .help("按来源 / 类型过滤")
        .popover(isPresented: $showFilterMenu, arrowEdge: .top) {
            SourceFilterMenu(
                kinds: availableKinds,
                sources: availableSources,
                kindFilter: $kindFilter,
                sourceFilter: $sourceFilter,
                onPick: { showFilterMenu = false }
            )
        }
    }

    // MARK: - 圆形图标按钮（返回剪贴板）

    private func circleButton(
        symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: Metric.circleButton, height: Metric.circleButton)
                .background(Color(nsColor: .controlColor).opacity(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.9, pressedOpacity: 0.8))
        .help(help)
    }

}

// MARK: - 筛选磁贴（剪贴板 / 收藏）

private struct ToolbarPill: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color(nsColor: .labelColor) : Color(nsColor: .secondaryLabelColor))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background {
                Capsule(style: .continuous)
                    .fill(Color(nsColor: .controlColor).opacity(backgroundOpacity))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                Color(nsColor: .separatorColor).opacity(isSelected ? 0.36 : 0.12),
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.95, pressedOpacity: 0.85))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isHovered)
        .help(title)
    }

    private var backgroundOpacity: Double {
        if isSelected {
            return isHovered ? 0.24 : 0.18
        }
        return isHovered ? 0.14 : 0.08
    }
}

// MARK: - 来源选项

/// 历史里出现过的一个来源 App（用于「应用」过滤分区）。
struct ClipboardSourceOption: Identifiable, Equatable {
    let name: String
    let bundleID: String?
    let icon: NSImage?

    var id: String { name }

    static func == (lhs: ClipboardSourceOption, rhs: ClipboardSourceOption) -> Bool {
        lhs.name == rhs.name && lhs.bundleID == rhs.bundleID
    }
}

// MARK: - 过滤菜单弹层（类型 / 应用）

private struct SourceFilterMenu: View {
    let kinds: [ClipboardKind]
    let sources: [ClipboardSourceOption]
    @Binding var kindFilter: ClipboardKind?
    @Binding var sourceFilter: String?
    let onPick: () -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !kinds.isEmpty {
                    section(title: "类型") {
                        ForEach(kinds, id: \.self) { kind in
                            FilterPill(
                                title: kind.label,
                                symbol: kind.symbolName,
                                icon: nil,
                                isSelected: kindFilter == kind
                            ) {
                                kindFilter = (kindFilter == kind) ? nil : kind
                                onPick()
                            }
                        }
                    }
                }

                if !sources.isEmpty {
                    section(title: "应用") {
                        ForEach(sources) { source in
                            FilterPill(
                                title: source.name,
                                symbol: "app.dashed",
                                icon: source.icon,
                                isSelected: sourceFilter == source.name
                            ) {
                                sourceFilter = (sourceFilter == source.name) ? nil : source.name
                                onPick()
                            }
                        }
                    }
                }

                if kinds.isEmpty && sources.isEmpty {
                    Text("暂无可筛选的记录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .padding(18)
        }
        .frame(width: 540)
        .frame(maxHeight: 460)
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                content()
            }
        }
    }
}

private struct FilterPill: View {
    let title: String
    let symbol: String
    let icon: NSImage?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color(nsColor: .controlAccentColor) : Color(nsColor: .labelColor))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                Capsule(style: .continuous)
                    .fill(backgroundColor)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                isSelected
                                    ? Color(nsColor: .controlAccentColor).opacity(0.5)
                                    : Color(nsColor: .separatorColor).opacity(0.18),
                                lineWidth: 1
                            )
                    }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.96, pressedOpacity: 0.9))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
        }
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(nsColor: .controlAccentColor).opacity(isHovered ? 0.22 : 0.16)
        }
        return Color(nsColor: .controlColor).opacity(isHovered ? 0.16 : 0.08)
    }
}
