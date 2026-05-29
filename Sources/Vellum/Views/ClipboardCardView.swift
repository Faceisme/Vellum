import SwiftUI

struct ClipboardCardView: View {
    let item: ClipboardItem
    let index: Int
    var isSelected: Bool = false
    var onSelect: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onCopy: () -> Void = {}
    var onDelete: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }

    @State private var isHovered = false

    private var highlighted: Bool { isHovered || isSelected }

    // Paste-style fixed selection blue (≈ #0A84FF)
    private static let selectionBlue = Color(red: 0.04, green: 0.52, blue: 1.0)

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                header

                bodyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipped()
            .background {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.94))
            }
            .clipShape(RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
                    .stroke(
                        highlighted ? Self.selectionBlue : Color(nsColor: .separatorColor).opacity(0.28),
                        lineWidth: highlighted ? 2.5 : 0.8
                    )
            }
            .shadow(color: .black.opacity(highlighted ? 0.12 : 0.07), radius: highlighted ? 8 : 4, x: 0, y: highlighted ? 4 : 2)
        }
        .buttonStyle(VellumPressButtonStyle(pressedScale: 0.98, pressedOpacity: 0.96))
        .animation(.easeOut(duration: 0.15), value: highlighted)
        .onHover {
            isHovered = $0
            onHoverChanged($0)
        }
        .help("点击粘贴；右键更多操作")
        .contextMenu {
            Button(action: onToggleFavorite) {
                Label(item.isFavorite ? "取消收藏" : "收藏",
                      systemImage: item.isFavorite ? "star.slash" : "star")
            }
            Button(action: onCopy) {
                Label("复制到剪贴板", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var cardWidth: CGFloat { 232 }
    private var cardHeight: CGFloat { 234 }
    private var cardCornerRadius: CGFloat { 17 }
    private var headerHeight: CGFloat { 52 }
    private var contentInset: CGFloat { 14 }

    // MARK: - Body routing

    @ViewBuilder
    private var bodyContent: some View {
        if item.kind == .image {
            imageBody
        } else {
            VStack(spacing: 0) {
                content
                    .frame(width: cardWidth - contentInset * 2, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, contentInset)
                    .padding(.top, 12)

                footer
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            sourceAccent
                .frame(height: headerHeight)
                .overlay(alignment: .top) {
                    LinearGradient(
                        colors: [.white.opacity(0.14), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 16)
                }

            HStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind.label)
                        .font(.system(size: 16, weight: .bold))
                    Text(relativeTime(from: item.createdAt))
                        .font(.system(size: 12, weight: .semibold))
                        .opacity(0.85)
                }

                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
                        .padding(.top, 2)
                }

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.leading, 14)
            .padding(.top, 9)

            if let icon = item.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 2)
                    .padding(.top, 9)
                    .padding(.trailing, 10)
            }
        }
        .frame(width: cardWidth, height: headerHeight)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: cardCornerRadius, topTrailingRadius: cardCornerRadius))
    }

    // MARK: - Image body (checkerboard + centered dimension pill + index)

    private var imageBody: some View {
        ZStack {
            CheckerboardBackground()

            if let image = item.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .bottom) {
            Text(item.detail)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 7)
        }
        .overlay(alignment: .bottomTrailing) {
            indexLabel
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: Capsule())
                .padding(7)
        }
    }

    // MARK: - Non-image content

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .image:
            EmptyView()
        case .code:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                    Text("代码片段")
                }
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(sourceAccent)

                Text(item.rawText ?? "")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .lineLimit(6)
                    .foregroundStyle(.primary)
                    .padding(9)
                    .frame(width: cardWidth - contentInset * 2, alignment: .leading)
                    .background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .clipped()
            }
        case .link:
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.previewTitle ?? item.title)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(2)

                        Text(item.previewSubtitle ?? item.detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    linkThumbnail
                }

                Text(item.rawText ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(9)
                    .frame(width: cardWidth - contentInset * 2, alignment: .leading)
                    .background(sourceAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .clipped()
            }
        case .color:
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(colorFromHex(item.colorHex ?? "#FFFFFF"))
                    .frame(height: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.black.opacity(0.08), lineWidth: 1)
                    }
                Text(item.colorHex ?? "")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
            }
        case .file:
            VStack(alignment: .leading, spacing: 10) {
                fileThumbnail
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                Text(item.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .text:
            Text(item.rawText ?? "")
                .font(.system(size: 15, weight: .regular))
                .lineLimit(7)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Footer (centered metric + index label)

    private var footer: some View {
        ZStack {
            Text(footerText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack {
                Spacer()
                indexLabel
            }
        }
        .frame(height: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
    }

    private var indexLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 9, weight: .bold))
            Text("\(index)")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }

    private var footerText: String {
        item.detail
    }

    // MARK: - Pieces

    private var linkThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(sourceAccent.opacity(0.12))

            if let image = item.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            } else if let icon = item.sourceIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(sourceAccent)
            }
        }
        .frame(width: 56, height: 56)
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(0.42), lineWidth: 0.8)
        }
    }

    private var fileThumbnail: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(sourceAccent.opacity(0.10))
                .frame(width: 66, height: 66)

            if let image = item.previewImage ?? item.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 42, height: 42)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(sourceAccent)
            }
        }
    }

    // MARK: - Colors

    private var accent: Color {
        switch item.kind {
        case .image, .text: Color(red: 0.11, green: 0.48, blue: 0.95)
        case .code: Color(red: 0.48, green: 0.36, blue: 0.84)
        case .link: Color(red: 0.08, green: 0.55, blue: 0.68)
        case .color: Color(red: 0.94, green: 0.42, blue: 0.28)
        case .file: Color(red: 0.22, green: 0.52, blue: 0.86)
        }
    }

    private var sourceAccent: Color {
        let source = [item.sourceBundleIdentifier, item.sourceAppName]
            .compactMap(\.self)
            .joined(separator: " ")
            .lowercased()

        if source.contains("wechat") || source.contains("微信") {
            return Color(red: 0.02, green: 0.78, blue: 0.40)
        }
        if source.contains("chrome") {
            return Color(red: 0.12, green: 0.49, blue: 0.94)
        }
        if source.contains("safari") {
            return Color(red: 0.06, green: 0.50, blue: 0.95)
        }
        if source.contains("terminal") || source.contains("iterm") {
            return Color(red: 0.38, green: 0.36, blue: 0.86)
        }
        if source.contains("finder") {
            return Color(red: 0.33, green: 0.67, blue: 0.91)
        }
        if item.kind == .image {
            return Color(red: 0.96, green: 0.34, blue: 0.15)
        }
        if item.kind == .link {
            return Color(red: 0.10, green: 0.48, blue: 0.88)
        }
        return accent
    }

    // MARK: - Helpers

    private func relativeTime(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "现在" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        return "\(seconds / 86400) 天前"
    }

    private func colorFromHex(_ hex: String) -> Color {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        raw.removeAll { $0 == "#" }

        var value: UInt64 = 0
        Scanner(string: raw).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        if raw.count == 3 {
            red = Double((value >> 8) & 0xF) / 15
            green = Double((value >> 4) & 0xF) / 15
            blue = Double(value & 0xF) / 15
        } else {
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }

        return Color(red: red, green: green, blue: blue)
    }
}

// MARK: - Checkerboard

private struct CheckerboardBackground: View {
    var square: CGFloat = 8
    var light = Color(white: 0.96)
    var dark = Color(white: 0.85)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(light))

            let cols = Int(ceil(size.width / square))
            let rows = Int(ceil(size.height / square))
            for row in 0..<max(rows, 0) {
                for col in 0..<max(cols, 0) where (row + col).isMultiple(of: 2) {
                    let rect = CGRect(
                        x: CGFloat(col) * square,
                        y: CGFloat(row) * square,
                        width: square,
                        height: square
                    )
                    context.fill(Path(rect), with: .color(dark))
                }
            }
        }
        .drawingGroup()
    }
}
