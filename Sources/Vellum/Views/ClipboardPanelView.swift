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
    /// 实际驱动过滤的查询词，相对 searchText 做 150ms 防抖，避免每次按键都重算过滤 + 重建卡片时间线（打字掉帧）
    @State private var debouncedQuery = ""
    @State private var searchFocusRequest = 0
    @State private var searchResetRequest = 0
    @State private var showFavoritesOnly = false
    @State private var selectedIndex = 0
    @State private var keyboardScrollRequest = 0
    /// 二次过滤：来源 App（按 sourceAppName）与类型（kind），与文本搜索、收藏叠加生效
    @State private var sourceFilter: String? = nil
    @State private var kindFilter: ClipboardKind? = nil
    @State private var showFilterMenu = false

    private var filteredItems: [ClipboardItem] {
        var result = monitor.items

        if showFavoritesOnly {
            result = result.filter(\.isFavorite)
        }

        if let kindFilter {
            result = result.filter { $0.kind == kindFilter }
        }

        if let sourceFilter {
            result = result.filter { $0.sourceAppName == sourceFilter }
        }

        let query = debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            // 只匹配用户能看到的内容字段；不再匹配来源 App 名和类型标签，
            // 否则像搜 "me" 会命中所有来自 "Chrome" 的项，看着像假搜索。
            result = result.filter { item in
                [
                    item.rawText,
                    item.title,
                    item.previewTitle,
                    item.previewSubtitle,
                    item.detail
                ]
                .compactMap(\.self)
                .contains { value in
                    value.localizedCaseInsensitiveContains(query)
                }
            }
        }

        return result
    }

    /// 历史里出现过的类型（用于过滤菜单「类型」分区），按枚举固定顺序
    private var availableKinds: [ClipboardKind] {
        let present = Set(monitor.items.map(\.kind))
        return ClipboardKind.allCases.filter { present.contains($0) }
    }

    /// 历史里出现过的来源 App（去重，按名称排序），用于过滤菜单「应用」分区
    private var availableSources: [ClipboardSourceOption] {
        var seen = Set<String>()
        var result: [ClipboardSourceOption] = []
        for item in monitor.items {
            let name = item.sourceAppName
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            result.append(
                ClipboardSourceOption(
                    name: name,
                    bundleID: item.sourceBundleIdentifier,
                    icon: item.sourceIcon
                )
            )
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 选中下标钳制在有效范围内（按给定数量，避免重复计算 filteredItems）
    private func clampedSelection(count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(0, selectedIndex), count - 1)
    }

    private var panelCornerRadius: CGFloat { 30 }

    private struct TimelineContentSignature: Equatable {
        let items: [TimelineItemSignature]
        let selectedIndex: Int
        let query: String
    }

    private struct TimelineItemSignature: Equatable {
        let id: UUID
        let isFavorite: Bool
        let previewTitle: String?
        let previewSubtitle: String?
        let previewImageID: ObjectIdentifier?
    }

    var body: some View {
        // 一次 body 只算一次过滤结果与选中下标，避免在 clampedSelection/timeline/每张卡片里重复全量 filter
        let items = filteredItems
        let selection = clampedSelection(count: items.count)
        return ZStack {
            // macOS 26 Liquid Glass — 用 .regular（磨砂）而非 .clear（高透）：后者要大量采样/折射
            // 背景，合成最贵；.regular 更实、合成更轻（对齐 Paste 的磨砂观感，降 WindowServer 负载）。
            // 底色也调实一些，进一步减少需要实时合成的背景面积。
            GlassEffectView(
                cornerRadius: panelCornerRadius,
                tintColor: NSColor.windowBackgroundColor.withAlphaComponent(0.76),
                style: .regular
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
                } else if items.isEmpty {
                    emptyState(title: showFavoritesOnly
                               ? "还没有收藏的项目（右键卡片可收藏）"
                               : "没有找到匹配的剪贴板项目")
                } else {
                    timeline(items: items, selection: selection,
                             query: debouncedQuery.trimmingCharacters(in: .whitespacesAndNewlines))
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
        .onReceive(NotificationCenter.default.publisher(for: .vellumNavCancelSearch)) { _ in
            // 点击下方卡片区即收起；过滤菜单开着时先让它消化这次点击（关闭弹层），不收起搜索
            if isSearching && !showFilterMenu {
                collapseSearch()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumPanelResetSearch)) { _ in
            resetSearchState()
        }
        .task(id: searchText) {
            // 清空立即生效；输入时等 150ms 再过滤，打字过程不触发卡片重建
            if searchText.isEmpty {
                debouncedQuery = ""
                return
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            debouncedQuery = searchText
        }
    }

    // MARK: - 键盘选择/删除

    private func moveSelection(_ delta: Int, requestScroll: Bool = false) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = min(max(0, clampedSelection(count: count) + delta), count - 1)
        if requestScroll {
            keyboardScrollRequest += 1
        }
    }

    private func deleteSelected() {
        let items = filteredItems
        guard !items.isEmpty else { return }
        let target = items[clampedSelection(count: items.count)]
        withAnimation(.easeOut(duration: 0.18)) {
            monitor.delete(target)
        }
        // 删除后选中项停在原位（即原来的下一项），并钳制范围
        selectedIndex = min(selectedIndex, max(0, items.count - 2))
    }

    private func selectCurrent() {
        let items = filteredItems
        guard !items.isEmpty else { return }
        onSelect(items[clampedSelection(count: items.count)])
    }

    private func expandSearch() {
        // 第一次 Cmd+F：展开并聚焦搜索框；已在搜索中再按：切换「来源 / 类型」过滤菜单
        guard !isSearching else {
            showFilterMenu.toggle()
            return
        }

        isSearching = true
        searchFocusRequest += 1
    }

    private func resetSearchState() {
        isSearching = false
        searchText = ""
        debouncedQuery = ""
        showFilterMenu = false
        sourceFilter = nil
        kindFilter = nil
        searchResetRequest += 1
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

    private var toolbarCluster: some View {
        SearchToolbarClusterView(
            isSearching: $isSearching,
            searchText: $searchText,
            showFavoritesOnly: $showFavoritesOnly,
            focusRequest: $searchFocusRequest,
            resetRequest: $searchResetRequest,
            showFilterMenu: $showFilterMenu,
            sourceFilter: $sourceFilter,
            kindFilter: $kindFilter,
            availableKinds: availableKinds,
            availableSources: availableSources,
            onClipboardSelected: {
                selectedIndex = 0
            },
            onFavoritesSelected: {
                selectedIndex = 0
            },
            onSearchCancelled: {
                collapseSearch()
            }
        )
        .frame(width: 522, height: 44)
    }

    private func collapseSearch() {
        guard isSearching else { return }
        isSearching = false
        showFilterMenu = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            if !isSearching {
                searchText = ""
                debouncedQuery = ""
                sourceFilter = nil
                kindFilter = nil
            }
        }
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

    private func timeline(items: [ClipboardItem], selection: Int, query: String) -> some View {
        SmoothHorizontalScrollView(
            selectedIndex: selection,
            scrollRequest: keyboardScrollRequest,
            contentSignature: timelineSignature(items: items, selection: selection, query: query),
            itemCount: items.count,
            itemWidth: 232,
            spacing: 18
        ) {
            HStack(alignment: .top, spacing: 18) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    ClipboardCardView(
                        item: item,
                        index: index + 1,
                        isSelected: index == selection,
                        searchQuery: query,
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

    private func timelineSignature(
        items: [ClipboardItem],
        selection: Int,
        query: String
    ) -> TimelineContentSignature {
        TimelineContentSignature(
            items: items.map {
                TimelineItemSignature(
                    id: $0.id,
                    isFavorite: $0.isFavorite,
                    previewTitle: $0.previewTitle,
                    previewSubtitle: $0.previewSubtitle,
                    previewImageID: $0.previewImage.map(ObjectIdentifier.init)
                )
            },
            selectedIndex: selection,
            query: query
        )
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

    private func toolbarPlainIcon(
        _ symbol: String,
        size: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        ToolbarIconButton(symbol: symbol, size: size, help: help, action: action)
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
