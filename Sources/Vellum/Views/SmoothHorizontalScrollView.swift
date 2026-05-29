import AppKit
import SwiftUI

struct SmoothHorizontalScrollView<Content: View>: NSViewRepresentable {
    let selectedIndex: Int
    let scrollRequest: Int
    let itemWidth: CGFloat
    let spacing: CGFloat
    let content: Content

    init(
        selectedIndex: Int,
        scrollRequest: Int,
        itemWidth: CGFloat,
        spacing: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.selectedIndex = selectedIndex
        self.scrollRequest = scrollRequest
        self.itemWidth = itemWidth
        self.spacing = spacing
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        scrollView.documentView = hostingView
        context.coordinator.hostingView = hostingView
        return scrollView
    }

    func updateNSView(_ scrollView: VellumSmoothScrollView, context: Context) {
        guard let hostingView = context.coordinator.hostingView else { return }

        hostingView.rootView = content
        let fittingSize = hostingView.fittingSize
        hostingView.frame = NSRect(
            x: 0,
            y: 0,
            width: max(fittingSize.width, scrollView.contentView.bounds.width),
            height: max(fittingSize.height, scrollView.contentView.bounds.height)
        )

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
    }
}

final class VellumSmoothScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard let documentView else {
            super.scrollWheel(with: event)
            return
        }

        let horizontal = event.scrollingDeltaX
        let vertical = event.scrollingDeltaY
        let delta = abs(horizontal) > abs(vertical) ? horizontal : vertical
        guard abs(delta) > 0 else { return }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 6.0 : 72
        let currentX = contentView.bounds.origin.x
        let maxX = max(0, documentView.frame.width - contentView.bounds.width)
        let targetX = min(max(0, currentX - delta * multiplier), maxX)

        contentView.setBoundsOrigin(NSPoint(x: targetX, y: 0))
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
        let targetX = min(max(0, itemMidX - visibleWidth / 2), maxX)
        let target = NSPoint(x: targetX, y: 0)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.92, 0.20, 1)
                contentView.animator().setBoundsOrigin(target)
            } completionHandler: {
                Task { @MainActor in
                    self.reflectScrolledClipView(self.contentView)
                }
            }
        } else {
            contentView.setBoundsOrigin(target)
            reflectScrolledClipView(contentView)
        }
    }
}
