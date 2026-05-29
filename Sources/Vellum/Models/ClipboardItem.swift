import AppKit

enum ClipboardKind: String, CaseIterable {
    case image
    case text
    case code
    case link
    case color
    case file

    var label: String {
        switch self {
        case .image: "图片"
        case .text: "文本"
        case .code: "代码"
        case .link: "链接"
        case .color: "颜色"
        case .file: "文件"
        }
    }

    var symbolName: String {
        switch self {
        case .image: "photo"
        case .text: "text.alignleft"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .color: "paintpalette"
        case .file: "doc"
        }
    }
}

struct ClipboardItem: Identifiable, Equatable {
    let id = UUID()
    let kind: ClipboardKind
    let title: String
    let subtitle: String
    let detail: String
    let rawText: String?
    let image: NSImage?
    let fileURLs: [URL]
    let colorHex: String?
    let linkURL: URL?
    var previewTitle: String?
    var previewSubtitle: String?
    var previewImage: NSImage?
    let sourceAppName: String
    let sourceBundleIdentifier: String?
    let sourceIcon: NSImage?
    let createdAt: Date
    let fingerprint: String
    var isFavorite: Bool = false
    /// 原始富文本（RTF）数据，用于非“纯文本”模式下保留格式粘贴
    var richRTFData: Data? = nil

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool {
        lhs.id == rhs.id && lhs.isFavorite == rhs.isFavorite
    }
}
