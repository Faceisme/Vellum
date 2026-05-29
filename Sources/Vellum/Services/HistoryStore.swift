import AppKit
import UniformTypeIdentifiers

/// 把剪贴板历史持久化到 App 容器：
/// - 文本/链接/颜色/文件 直接存进 JSON 索引
/// - 图片落地为单独的 PNG，索引里只存文件名
/// - 来源 App 图标不存盘，加载时按 bundleId 重新取
final class HistoryStore {
    private let directory: URL
    private let imagesDirectory: URL
    private let indexURL: URL

    private let fileManager = FileManager.default

    init() {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory

        directory = base.appendingPathComponent("Vellum", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        indexURL = directory.appendingPathComponent("history.json")

        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Load

    func load() -> [ClipboardItem] {
        guard
            let data = try? Data(contentsOf: indexURL),
            let stored = try? JSONDecoder().decode([StoredItem].self, from: data)
        else {
            return []
        }
        return stored.map { makeItem(from: $0) }
    }

    // MARK: - Save

    func save(_ items: [ClipboardItem]) {
        let stored = items.map { StoredItem(from: $0) }

        // 写图片（不存在才写）
        for item in items where item.image != nil {
            let url = imagesDirectory.appendingPathComponent(imageFilename(for: item.fingerprint))
            if !fileManager.fileExists(atPath: url.path), let data = pngData(item.image!) {
                try? data.write(to: url)
            }
        }

        // 写索引
        if let data = try? JSONEncoder().encode(stored) {
            try? data.write(to: indexURL)
        }

        // 清理无引用的孤儿图片
        let referenced = Set(items.compactMap { $0.image != nil ? imageFilename(for: $0.fingerprint) : nil })
        if let files = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) {
            for file in files where !referenced.contains(file) {
                try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(file))
            }
        }
    }

    // MARK: - Mapping

    private func makeItem(from stored: StoredItem) -> ClipboardItem {
        var kind = ClipboardKind(rawValue: stored.kind) ?? .text
        var image = stored.imageFile.flatMap {
            NSImage(contentsOf: imagesDirectory.appendingPathComponent($0))
        }
        let fileURLs = stored.filePaths.map { URL(fileURLWithPath: $0) }

        if image == nil,
           kind == .file,
           fileURLs.count == 1,
           let imageURL = fileURLs.first,
           isImageFile(imageURL) {
            image = NSImage(contentsOf: imageURL)
        }

        let detail: String
        if let image, kind == .file, fileURLs.count == 1, isImageFile(fileURLs[0]) {
            kind = .image
            detail = "\(Int(image.size.width)) × \(Int(image.size.height))"
        } else {
            detail = stored.detail
        }

        return ClipboardItem(
            kind: kind,
            title: kind == .image && !fileURLs.isEmpty ? "图片" : stored.title,
            subtitle: stored.subtitle,
            detail: detail,
            rawText: stored.rawText,
            image: image,
            fileURLs: fileURLs,
            colorHex: stored.colorHex,
            linkURL: stored.linkURLString.flatMap { URL(string: $0) },
            previewTitle: stored.previewTitle,
            previewSubtitle: stored.previewSubtitle,
            previewImage: image,
            sourceAppName: stored.sourceAppName,
            sourceBundleIdentifier: stored.sourceBundleIdentifier,
            sourceIcon: icon(forBundleIdentifier: stored.sourceBundleIdentifier),
            createdAt: stored.createdAt,
            fingerprint: stored.fingerprint,
            isFavorite: stored.isFavorite,
            richRTFData: stored.rtfBase64.flatMap { Data(base64Encoded: $0) }
        )
    }

    private func icon(forBundleIdentifier bundleId: String?) -> NSImage? {
        guard let bundleId else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }

        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"].contains(ext)
    }

    private func imageFilename(for fingerprint: String) -> String {
        let safe = fingerprint.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(safe).prefix(180) + ".png"
    }

    private func pngData(_ image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

private struct StoredItem: Codable {
    var kind: String
    var title: String
    var subtitle: String
    var detail: String
    var rawText: String?
    var imageFile: String?
    var filePaths: [String]
    var colorHex: String?
    var linkURLString: String?
    var previewTitle: String?
    var previewSubtitle: String?
    var sourceAppName: String
    var sourceBundleIdentifier: String?
    var createdAt: Date
    var fingerprint: String
    var isFavorite: Bool
    var rtfBase64: String?

    init(from item: ClipboardItem) {
        kind = item.kind.rawValue
        title = item.title
        subtitle = item.subtitle
        detail = item.detail
        rawText = item.rawText
        imageFile = item.image != nil ? StoredItem.imageFilename(for: item.fingerprint) : nil
        filePaths = item.fileURLs.map(\.path)
        colorHex = item.colorHex
        linkURLString = item.linkURL?.absoluteString
        previewTitle = item.previewTitle
        previewSubtitle = item.previewSubtitle
        sourceAppName = item.sourceAppName
        sourceBundleIdentifier = item.sourceBundleIdentifier
        createdAt = item.createdAt
        fingerprint = item.fingerprint
        isFavorite = item.isFavorite
        rtfBase64 = item.richRTFData?.base64EncodedString()
    }

    static func imageFilename(for fingerprint: String) -> String {
        let safe = fingerprint.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
        return String(safe).prefix(180) + ".png"
    }
}
