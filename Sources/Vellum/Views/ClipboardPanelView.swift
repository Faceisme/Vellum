import SwiftUI

struct ClipboardPanelView: View {
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject private var settings = AppSettings.shared

    let onSelect: (ClipboardItem) -> Void
    let onClear: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void
    let onClose: () -> Void

    @State private var isSearching = false
    @State private var searchText = ""
    @State private var searchFieldReady = false
    @State private var didWarmSearchField = false
    @State private var showFavoritesOnly = false
    @State private var selectedIndex = 0
    @State private var keyboardScrollRequest = 0
    @FocusState private var searchFieldFocused: Bool

    private var filteredItems: [ClipboardItem] {
        var result = monitor.items

        if showFavoritesOnly {
            result = result.filter(\.isFavorite)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            result = result.filter { item in
                [
                    item.title,
                    item.detail,
                    item.rawText,
                    item.previewTitle,
                    item.previewSubtitle,
                    item.sourceAppName,
                    item.kind.label
                ]
                .compactMap(\.self)
                .contains { value in
                    value.localizedCaseInsensitiveContains(query)
                }
            }
        }

        return result
    }

    /// 选中下标钳制在有效范围内
    private var clampedSelection: Int {
        let count = filteredItems.count
        guard count > 0 else { return 0 }
        return min(max(0, selectedIndex), count - 1)
    }

    private var panelCornerRadius: CGFloat { 30 }
    private var searchAnimation: Animation {
        .smooth(duration: 0.30, extraBounce: 0)
    }

    var body: some View {
        ZStack {
            // macOS 26 Liquid Glass — 保留通透感，同时提高底板不透明度。
            // 阴影改用原生 .shadow()（GPU 优化），不再用全屏 .blur 矩形（入场每帧重算高斯模糊会卡）。
            GlassEffectView(
                cornerRadius: panelCornerRadius,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.66),
                style: .clear
            )
            .clipShape(RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: panelCornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.55), .white.opacity(0.10)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: .black.opacity(0.22), radius: 26, x: 0, y: 11)

            VStack(spacing: 0) {
                toolbar
                    .padding(.horizontal, 28)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                if monitor.items.isEmpty {
                    emptyState(title: "复制内容后会显示在这里")
                } else if filteredItems.isEmpty {
                    emptyState(title: showFavoritesOnly
                               ? "还没有收藏的项目（右键卡片可收藏）"
                               : "没有找到匹配的剪贴板项目")
                } else {
                    timeline(items: filteredItems)
                }
            }
        }
        .padding(.horizontal, 6)
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavLeft)) { _ in moveSelection(-1, requestScroll: true) }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavRight)) { _ in moveSelection(1, requestScroll: true) }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavDelete)) { _ in deleteSelected() }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavSelect)) { _ in selectCurrent() }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavEscape)) { _ in collapseSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavStartSearch)) { _ in
            expandSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavCancelSearch)) { notification in
            if isSearching && !isSearchFieldClick(notification) {
                collapseSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavWarmSearch)) { _ in
            warmSearchField()
        }
    }

    // MARK: - 键盘选择/删除

    private func moveSelection(_ delta: Int, requestScroll: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, clampedSelection + delta), count - 1)
        if requestScroll {
            keyboardScrollRequest += 1
        }
    }

    private func deleteSelected() {
        guard !filteredItems.isEmpty else { return }
        let target = filteredItems[clampedSelection]
        withAnimation(.easeOut(duration: 0.18)) {
            monitor.delete(target)
        }
        // 删除后选中项停在原位（即原来的下一项），并钳制范围
        selectedIndex = min(selectedIndex, max(0, filteredItems.count - 1))
    }

    private func selectCurrent() {
        guard !filteredItems.isEmpty else { return }
        onSelect(filteredItems[clampedSelection])
    }

    private func expandSearch() {
        guard !isSearching else {
            searchFieldFocused = true
            return
        }

        withAnimation(searchAnimation) {
            isSearching = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            guard isSearching else { return }
            searchFieldReady = true
            DispatchQueue.main.async {
                searchFieldFocused = true
            }
        }
    }

    private func warmSearchField() {
        guard !didWarmSearchField, !isSearching else { return }
        didWarmSearchField = true
        searchFieldFocused = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
            if !isSearching {
                searchFieldFocused = false
            }
        }
    }

    private func isSearchFieldClick(_ notification: Notification) -> Bool {
        guard
            let userInfo = notification.userInfo,
            let x = userInfo["x"] as? CGFloat,
            let y = userInfo["y"] as? CGFloat,
            let width = userInfo["width"] as? CGFloat,
            let height = userInfo["height"] as? CGFloat
        else {
            return false
        }

        let searchWidth: CGFloat = 392
        let trailingControlsWidth: CGFloat = 132
        let clusterWidth = searchWidth + trailingControlsWidth
        let searchMinX = width / 2 - clusterWidth / 2 - 10
        let searchMaxX = searchMinX + searchWidth + 20
        let searchMinY = height - 68
        let searchMaxY = height - 12

        return x >= searchMinX
            && x <= searchMaxX
            && y >= searchMinY
            && y <= searchMaxY
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            toolbarPlainIcon("arrow.clockwise", size: 15, help: "刷新剪贴板") {}
                .opacity(0.55)
                .frame(width: 34, height: 34)

            Spacer(minLength: 20)

            toolbarCluster

            Spacer(minLength: 20)

            moreMenu
        }
        .frame(height: 44)
    }

    private var clipboardChip: some View {
        ToolbarChipButton(
            title: "剪贴板",
            symbolName: "clock.arrow.circlepath",
            dotColor: nil,
            isSelected: !showFavoritesOnly
        ) {
            withAnimation(.smooth(duration: 0.2)) { showFavoritesOnly = false }
            selectedIndex = 0
        }
    }

    private var clipboardModeButton: some View {
        Button {
            if isSearching {
                collapseSearch()
            } else {
                withAnimation(.smooth(duration: 0.2)) { showFavoritesOnly = false }
                selectedIndex = 0
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: isSearching ? 16 : 13, weight: isSearching ? .regular : .semibold))
                    .frame(width: isSearching ? 34 : 15, height: 30)

                Text("剪贴板")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .opacity(isSearching ? 0 : 1)
                    .frame(width: isSearching ? 0 : 42, alignment: .leading)
                    .clipped()
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, isSearching ? 0 : 12)
            .frame(width: isSearching ? 34 : 92, height: 30, alignment: .leading)
            .background(
                Color(nsColor: .controlColor).opacity(isSearching ? 0 : (!showFavoritesOnly ? 0.66 : 0.18)),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(.white.opacity(isSearching ? 0 : (!showFavoritesOnly ? 0.28 : 0)), lineWidth: 0.7)
            }
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.94, pressedOpacity: 0.86))
        .help(isSearching ? "返回剪贴板" : "剪贴板")
    }

    private var toolbarCluster: some View {
        let expandedWidth: CGFloat = 522
        let collapsedWidth: CGFloat = 222
        let collapsedStart = (expandedWidth - collapsedWidth) / 2
        let favoriteWidth: CGFloat = 76

        return ZStack(alignment: .leading) {
            searchControl
                .offset(x: isSearching ? 0 : collapsedStart)

            clipboardModeButton
                .offset(x: isSearching ? 402 : collapsedStart + 44)

            favoritesChip
                .frame(width: favoriteWidth, height: 34)
                .offset(x: isSearching ? 446 : collapsedStart + 146)
        }
        .frame(width: expandedWidth, height: 44, alignment: .leading)
        .clipped()
    }

    private var favoritesChip: some View {
        ToolbarChipButton(
            title: "收藏",
            symbolName: "star.fill",
            dotColor: nil,
            isSelected: showFavoritesOnly
        ) {
            withAnimation(.smooth(duration: 0.2)) { showFavoritesOnly = true }
            selectedIndex = 0
        }
    }

    private func collapseSearch() {
        guard isSearching else { return }
        searchFieldReady = false
        searchFieldFocused = false
        withAnimation(searchAnimation) {
            isSearching = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
            if !isSearching {
                searchText = ""
            }
        }
    }

    private var searchControl: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: isSearching ? 14 : 17, style: .continuous)
                .fill(Color(nsColor: .controlColor).opacity(0.72))
                .opacity(isSearching ? 1 : 0)

            searchFieldContent
                .padding(.horizontal, isSearching ? 9 : 0)
        }
        .frame(width: isSearching ? 392 : 34, height: isSearching ? 28 : 34, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: isSearching ? 14 : 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: isSearching ? 14 : 17, style: .continuous)
                .stroke(
                    isSearching
                    ? (searchFieldFocused ? Color.blue.opacity(0.78) : .white.opacity(0.26))
                    : .clear,
                    lineWidth: searchFieldFocused ? 1.6 : 0.8
                )
        }
        .shadow(color: .black.opacity(isSearching ? 0.06 : 0), radius: 6, x: 0, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: isSearching ? 14 : 17, style: .continuous))
        .onTapGesture {
            expandSearch()
        }
    }

    private var searchFieldContent: some View {
        HStack(spacing: 7) {
            Button {
                expandSearch()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: isSearching ? 12.5 : 16, weight: .semibold))
                    .frame(width: isSearching ? 14 : 34, height: isSearching ? 20 : 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSearching ? .secondary : Color(nsColor: .labelColor).opacity(0.92))

            ZStack(alignment: .leading) {
                if isSearching && !searchFieldReady {
                    Text("搜索")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.48))
                }

                TextField(
                    "",
                    text: $searchText,
                    prompt: Text("搜索")
                        .foregroundStyle(.secondary.opacity(0.48))
                )
                .textFieldStyle(.plain)
                .focused($searchFieldFocused)
                .font(.system(size: 12.5, weight: .medium))
                .opacity(searchFieldReady ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(searchFieldReady)

            Button {
                searchText = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 14, height: 18)
            }
            .buttonStyle(VellumPressButtonStyle(pressedScale: 0.88, pressedOpacity: 0.78))
            .foregroundStyle(.secondary)
            .opacity(searchFieldReady && !searchText.isEmpty ? 1 : 0)
            .allowsHitTesting(searchFieldReady && !searchText.isEmpty)

            // Decorative filter glyph (筛选占位，返回剪贴板请用右侧时钟按钮)
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary.opacity(0.7))
                .opacity(isSearching ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private var moreMenu: some View {
        Menu {
            Button("打开设置", action: onSettings)
            Divider()
            Button("退出 Vellum", role: .destructive, action: onQuit)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("更多")
    }

    private func timeline(items: [ClipboardItem]) -> some View {
        SmoothHorizontalScrollView(
            selectedIndex: clampedSelection,
            scrollRequest: keyboardScrollRequest,
            itemWidth: 232,
            spacing: 18
        ) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipboardCardView(
                        item: item,
                        index: index + 1,
                        isSelected: index == clampedSelection,
                        onSelect: { onSelect(item) },
                        onToggleFavorite: { monitor.toggleFavorite(item) },
                        onCopy: { monitor.restore(item) },
                        onDelete: {
                            withAnimation(.easeOut(duration: 0.18)) {
                                monitor.delete(item)
                            }
                        },
                        onHoverChanged: { hovering in
                            if hovering { selectedIndex = index }
                        }
                    )
                    .id(item.id)
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 2)
            .padding(.bottom, 16)
        }
    }

    private func emptyState(title: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)

            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)

            Text("按 \(settings.launchShortcut?.displayString ?? "菜单栏") 呼出 Vellum，点击卡片会复制回系统剪贴板。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private func toolbarPlainIcon(
        _ symbol: String,
        size: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        ToolbarIconButton(symbol: symbol, size: size, help: help, action: action)
    }

    private func toolbarChip<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            content()
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 15)
        .frame(height: 34)
        .background(Color(nsColor: .controlColor).opacity(0.58), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.26), lineWidth: 0.7)
        }
    }
}

private struct ToolbarIconButton: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .regular))
                .frame(width: 38, height: 38)
                .contentShape(Rectangle())
                .background(iconBackground, in: Circle())
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.86, pressedOpacity: 0.78))
        .foregroundStyle(Color(nsColor: .labelColor).opacity(0.92))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isHovered)
        .help(help)
    }

    private var iconBackground: Color {
        Color(nsColor: .controlColor).opacity(isHovered ? 0.42 : 0)
    }
}

private struct ToolbarChipButton: View {
    let title: String
    let symbolName: String?
    let dotColor: Color?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let symbolName {
                    Image(systemName: symbolName)
                        .font(.system(size: 13, weight: .semibold))
                }

                if let dotColor {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 10, height: 10)
                }

                Text(title)
                    .font(.system(size: 13, weight: symbolName == nil ? .medium : .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(chipBackground, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(.white.opacity(isSelected || isHovered ? 0.28 : 0), lineWidth: 0.7)
            }
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.94, pressedOpacity: 0.86))
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.18, dampingFraction: 0.82), value: isHovered)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: isSelected)
    }

    private var chipBackground: Color {
        let opacity: Double
        if isSelected {
            opacity = 0.66
        } else if isHovered {
            opacity = 0.38
        } else {
            opacity = 0.18
        }

        return Color(nsColor: .controlColor).opacity(opacity)
    }
}

// MARK: - 搜索框横向拉伸展开过渡（对齐 Paste：从左侧拉伸长出 + 淡入）

private struct HorizontalStretch: ViewModifier {
    var scaleX: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: scaleX, y: 1, anchor: .leading)
    }
}

extension AnyTransition {
    static var searchExpand: AnyTransition {
        .modifier(
            active: HorizontalStretch(scaleX: 0.16),
            identity: HorizontalStretch(scaleX: 1)
        )
        .combined(with: .opacity)
    }
}
