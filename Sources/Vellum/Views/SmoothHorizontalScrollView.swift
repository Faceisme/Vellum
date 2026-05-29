import AppKit
import SwiftUI

/// 横向滚动容器：鼠标滚轮（纵向）也能横向滚动 + 平滑动画 + 键盘定位。
struct SmoothHorizontalScrollView<Content: View>: NSViewRepresentable {
    /// HStack 两侧的水平 padding（与 ClipboardPanelView.timeline 里保持一致）
    private static var horizontalPadding: CGFloat { 26 }

    let selectedIndex: Int
    let scrollRequest: Int
    let itemCount: Int
    let itemWidth: CGFloat
    let spacing: CGFloat
    let content: Content

    init(
        selectedIndex: Int,
        scrollRequest: Int,
        itemCount: Int,
        itemWidth: CGFloat,
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.selectedIndex = selectedIndex
        self.scrollRequest = scrollRequest
        self.itemCount = itemCount
        self.itemWidth = itemWidth
        self.spacing = spacing
        self.content = content()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 按数量直接算内容总宽，避免每次更新都触发 fittingSize 整树布局测量
    private func contentWidth() -> CGFloat {
        guard itemCount > 0 else { return 0 }
        return CGFloat(itemCount) * itemWidth
            + CGFloat(itemCount - 1) * spacing
            + Self.horizontalPadding * 2
    }

    func makeNSView(context: Context) -> VellumSmoothScrollView {
        let scrollView = VellumSmoothScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = false
        scrollView.verticalScrollElasticity = .none

        // 整条滚动链路都用图层支撑：滚动时只平移已缓存的图层位图，
        // 而不是每帧重画 SwiftUI 内容（自定义 scrollWheel 已绕过系统的 responsive scrolling，
        // 所以图层缓存是这里保证横向滚动不掉帧的关键）。
        scrollView.wantsLayer = true
        scrollView.contentView.wantsLayer = true

        let hostingView = NSHostingView(rootView: content)
        hostingView.wantsLayer = true
        hostingView.layerContentsRedrawPolicy = .onSetNeedsDisplay
        scrollView.documentView = hostingView
        scrollView.contentWidth = contentWidth()
        context.coordinator.hostingView = hostingView
        context.coordinator.lastItemCount = itemCount
        return scrollView
    }

    func updateNSView(_ scrollView: VellumSmoothScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }

        // rootView 必须重新赋值（卡片选中态/内容会变）；尺寸不在这里直接算，
        // 改由 scrollView.layout() 统一处理——避免 updateNSView 在 clip view 尚无有效高度时
        // （如时间线被空搜索结果换出后又换回）把内容定成错误尺寸且无法自愈，导致错位。
        hostingView.rootView = content
        scrollView.contentWidth = contentWidth() // 内容宽变化 -> 触发重新 layout
        context.coordinator.lastItemCount = itemCount

        if context.coordinator.lastScrollRequest != scrollRequest {
            context.coordinator.lastScrollRequest = scrollRequest
            scrollView.scrollToIndex(
                selectedIndex,
                itemWidth: itemWidth,
                spacing: spacing,
                animated: true
            )
        }
    }

    final class Coordinator {
        var hostingView: NSHostingView<Content>?
        var lastScrollRequest = 0
        var lastItemCount = 0
    }
}

final class VellumSmoothScrollView: NSScrollView {
    private var targetX: CGFloat = 0
    private var isAnimatingWheel = false

    /// 内容总宽（按卡片数量算），由 representable 设置；变化时重新布局
    var contentWidth: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    override func layout() {
        super.layout()
        sizeDocumentViewAndClampScroll()
    }

    /// 文档视图高度始终跟随可视区高度（避免列表换入换出时尺寸残留错位），
    /// 宽度取内容宽与可视宽的较大者；内容尺寸变化后把横向偏移钳回有效范围。
    private func sizeDocumentViewAndClampScroll() {
        guard let documentView else { return }

        let viewportHeight = contentView.bounds.height
        let viewportWidth = contentView.bounds.width
        guard viewportHeight > 0, viewportWidth > 0 else { return }

        let width = max(contentWidth, viewportWidth)
        let newFrame = NSRect(x: 0, y: 0, width: width, height: viewportHeight)
        if documentView.frame != newFrame {
            documentView.frame = newFrame
        }

        let maxX = max(0, width - viewportWidth)
        let currentX = contentView.bounds.origin.x
        let clampedX = min(max(0, currentX), maxX)
        if clampedX != currentX {
            contentView.setBoundsOrigin(NSPoint(x: clampedX, y: 0))
            targetX = clampedX
            reflectScrolledClipView(contentView)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        guard maxX > 0 else { return }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let delta = abs(deltaX) >= abs(deltaY) ? deltaX : deltaY
        guard delta != 0 else { return }

        if event.hasPreciseScrollingDeltas {
            // 触摸板：直接跟手（系统本身已平滑）
            let x = min(max(0, contentView.bounds.origin.x - delta), maxX)
            contentView.setBoundsOrigin(NSPoint(x: x, y: 0))
            reflectScrolledClipView(contentView)
            targetX = x
        } else {
            // 鼠标滚轮：每格固定步长累加，动画平滑滑过去
            let base = isAnimatingWheel ? targetX : contentView.bounds.origin.x
            let step: CGFloat = 90
            targetX = min(max(0, base - (delta > 0 ? step : -step)), maxX)
            animateWheelScroll()
        }
    }

    private func animateWheelScroll() {
        isAnimatingWheel = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.20
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            contentView.animator().setBoundsOrigin(NSPoint(x: targetX, y: 0))
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isAnimatingWheel = false
                self.reflectScrolledClipView(self.contentView)
            }
        }
        reflectScrolledClipView(contentView)
    }

    func scrollToIndex(
        _ index: Int,
        itemWidth: CGFloat,
        spacing: CGFloat,
        animated: Bool
    ) {
        guard let documentView else { return }

        let visibleWidth = contentView.bounds.width
        let itemStride = itemWidth + spacing
        let itemMidX = CGFloat(index) * itemStride + itemWidth / 2 + 26
        let maxX = max(0, documentView.frame.width - visibleWidth)
        let target = min(max(0, itemMidX - visibleWidth / 2), maxX)
        targetX = target
        let origin = NSPoint(x: target, y: 0)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.92, 0.20, 1)
                contentView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        } else {
            contentView.setBoundsOrigin(origin)
            reflectScrolledClipView(contentView)
        }
    }
}
