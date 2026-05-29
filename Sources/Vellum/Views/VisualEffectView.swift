import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        if nsView.material != material { nsView.material = material }
        if nsView.blendingMode != blendingMode { nsView.blendingMode = blendingMode }
        if nsView.state != state { nsView.state = state }
    }
}

struct GlassEffectView: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tintColor: NSColor?
    var style: NSGlassEffectView.Style = .regular

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.tintColor = tintColor
        view.style = style
        return view
    }

    func updateNSView(_ nsView: NSGlassEffectView, context: Context) {
        // 仅在实际变化时赋值，避免每次 body 重算（如 hover）都重设属性触发玻璃层重绘
        if nsView.cornerRadius != cornerRadius { nsView.cornerRadius = cornerRadius }
        if nsView.tintColor != tintColor { nsView.tintColor = tintColor }
        if nsView.style != style { nsView.style = style }
    }
}
