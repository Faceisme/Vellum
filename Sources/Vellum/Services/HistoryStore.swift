import AppKit
import UniformTypeIdentifiers

/// 把剪贴板历史持久化到 App 容器：
/// - 文本/链接/颜色/文件 直接存进 JSON 索引
/// - 图片落地为单独的 PNG，索引里只存文件名
/// - 来源 App 图标不存盘，加载时按 bundleId 重新取
@MainActor
final class HistoryStore {
    private let directory: URL
    private let imagesDirectory: URL
    private let indexURL: URL

    private let fileManager = FileManager.default

    /// 串行写盘队列：JSON 编码、文件写入、孤儿清理都放后台，避免阻塞主线程
    private let ioQueue = DispatchQueue(label: "com.vellum.historystore.io", qos: .utility)

    /// 已落地的图片文件名缓存（仅主线程访问），避免每次保存在主线程 stat 磁盘判断是否已写
    private var writtenImageFilenames: Set<String> = []

    /// 保存计数，用于把孤儿图片清理降频（不必每次保存都扫描整个目录）
    private var saveCounter = 0
    private static let orphanCleanupInterval = 12

    init() {
        let base = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory

        directory = base.appendingPathComponent("Vellum", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("images", isDirectory: true)
        indexURL = directory.appendingPathComponent("history.json")

        try? fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        // 一次性预热已写图片名缓存（仅扫描文件名，不加载图片，启动开销可忽略）
        if let files = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) {
            writtenImageFilenames = Set(files)
        }
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

    /// 在主线程调用：准备好不可变快照（含新图片 PNG 数据）后，把磁盘 I/O 全部丢到后台串行队列。
    /// NSImage 不是线程安全的，因此 PNG 转码仍在主线程完成（且仅对尚未落地的新图片做一次）。
    func save(_ items: [ClipboardItem]) {
        let stored = items.map { StoredItem(from: $0) }

        // 仅对“还没写过盘”的新图片做 PNG 转码，避免每次保存重复转码大图
        var newImages: [(filename: String, data: Data)] = []
        var referenced: Set<String> = []
        for item in items where item.image != nil {
            let filename = imageFilename(for: item.fingerprint)
            referenced.insert(filename)
            if !writtenImageFilenames.contains(filename), let data = pngData(item.image!) {
                newImages.append((filename, data))
                writtenImageFilenames.insert(filename)
            }
        }

        saveCounter += 1
        // 清空历史时立即清理孤儿，其余情况降频执行
        let shouldCleanOrphans = stored.isEmpty || saveCounter % Self.orphanCleanupInterval == 0
        if stored.isEmpty { writtenImageFilenames.removeAll() }

        // 只捕获 Sendable 值类型（URL/数组/Set/Bool）的不可变副本，不捕获 self，避免数据竞争
        let imagesDirectory = self.imagesDirectory
        let indexURL = self.indexURL
        let newImagesSnapshot = newImages
        let referencedSnapshot = referenced
        ioQueue.async {
            Self.writeToDisk(
                stored: stored,
                newImages: newImagesSnapshot,
                referenced: referencedSnapshot,
                cleanOrphans: shouldCleanOrphans,
                imagesDirectory: imagesDirectory,
                indexURL: indexURL
            )
        }
    }

    /// 同步落盘并等待完成（退出前调用，避免丢数据）
    func flush() {
        ioQueue.sync {}
    }

    /// 后台串行队列执行：不触碰任何主线程状态，只用传入的不可变快照
    nonisolated private static func writeToDisk(
        stored: [StoredItem],
        newImages: [(filename: String, data: Data)],
        referenced: Set<String>,
        cleanOrphans: Bool,
        imagesDirectory: URL,
        indexURL: URL
    ) {
        let fileManager = FileManager.default

        // 写新图片
        for image in newImages {
            let url = imagesDirectory.appendingPathComponent(image.filename)
            do {
                try image.data.write(to: url, options: .atomic)
            } catch {
                NSLog("Vellum: 写入图片失败 \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // 原子写索引
        do {
            let data = try JSONEncoder().encode(stored)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("Vellum: 写入历史索引失败 \(indexURL.path): \(error.localizedDescription)")
        }

        // 孤儿图片清理（降频执行）
        guard cleanOrphans else { return }
        if let files = try? fileManager.contentsOfDirectory(atPath: imagesDirectory.path) {
            for file in files where !referenced.contains(file) {
                try? fileManager.removeItem(at: imagesDirectory.appendingPathComponent(file))
            }
        }
    }

    /// 粘贴时按需加载某个指纹对应的全分辨率原图（内存里只留缩略图）
    func fullImage(for fingerprint: String) -> NSImage? {
        let url = imagesDirectory.appendingPathComponent(imageFilename(for: fingerprint))
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return NSImage(contentsOf: url)
    }

    // MARK: - Mapping

    private func makeItem(from stored: StoredItem) -> ClipboardItem {
        var kind = ClipboardKind(rawValue: stored.kind) ?? .text
        // 加载历史时只放缩略图，避免几十张全分辨率位图常驻内存；原图按需从磁盘加载
        var image = stored.imageFile.flatMap {
            NSImage(contentsOf: imagesDirectory.appendingPathComponent($0))?.vellumThumbnail()
        }
        let fileURLs = stored.filePaths.map { URL(fileURLWithPath: $0) }

        if image == nil,
           kind == .file,
           fileURLs.count == 1,
           let imageURL = fileURLs.first,
           isImageFile(imageURL) {
            image = NSImage(contentsOf: imageURL)?.vellumThumbnail()
        }

        // 用保存时记录的原始尺寸（stored.detail），不要用缩略图尺寸，避免显示成缩略图分辨率
        if image != nil, kind == .file, fileURLs.count == 1, isImageFile(fileURLs[0]) {
            kind = .image
        }
        let detail = stored.detail

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
