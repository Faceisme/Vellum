import AppKit
import LinkPresentation
import UniformTypeIdentifiers

@MainActor
final class ClipboardMonitor: ObservableObject {
    @Published private(set) var items: [ClipboardItem] = []

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxItems = 36

    private static let favoritesKey = "vellum.favorites"
    private var favoriteFingerprints: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "vellum.favorites") ?? [])

    private let store = HistoryStore()
    private var saveGeneration = 0

    func start() {
        items = store.load()
        NSLog("Vellum: 启动加载历史 \(items.count) 条")
        pruneExpired()
        captureCurrentPasteboard()

        timer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollPasteboard()
                self?.pruneExpired()
            }
        }
        timer?.tolerance = 0.2
    }

    func clear() {
        items.removeAll()
        flushNow()
    }

    func delete(_ item: ClipboardItem) {
        items.removeAll { $0.id == item.id }
        flushNow()
    }

    func toggleFavorite(_ item: ClipboardItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()

        let fingerprint = items[index].fingerprint
        if items[index].isFavorite {
            favoriteFingerprints.insert(fingerprint)
        } else {
            favoriteFingerprints.remove(fingerprint)
        }
        UserDefaults.standard.set(Array(favoriteFingerprints), forKey: Self.favoritesKey)
        flushNow()
    }

    /// 立即同步落盘（退出前、删除/收藏/清空时调用，避免丢数据）
    func flushNow() {
        saveGeneration += 1 // 取消挂起的防抖保存
        store.save(items)
    }

    /// 按设置的保留时长清理过期项（收藏豁免）
    private func pruneExpired() {
        guard let interval = AppSettings.shared.retentionInterval else { return }
        let cutoff = Date().addingTimeInterval(-interval)
        let before = items.count
        items.removeAll { !$0.isFavorite && $0.createdAt < cutoff }
        if items.count != before {
            saveSoon()
        }
    }

    /// 防抖保存：最后一次改动 0.8s 后落盘
    private func saveSoon() {
        saveGeneration += 1
        let generation = saveGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            Task { @MainActor in
                guard let self, generation == self.saveGeneration else { return }
                self.store.save(self.items)
            }
        }
    }

    func restore(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .image:
            if !item.fileURLs.isEmpty {
                pasteboard.writeObjects(item.fileURLs as [NSURL])
            } else if let image = item.image {
                pasteboard.writeObjects([image])
            }
        case .file:
            pasteboard.writeObjects(item.fileURLs as [NSURL])
        case .text, .code, .link, .color:
            // 非纯文本模式且存在富文本时，保留 RTF 格式
            if !AppSettings.shared.alwaysPlainText, let rtf = item.richRTFData {
                pasteboard.setData(rtf, forType: .rtf)
            }
            if let text = item.rawText {
                pasteboard.setString(text, forType: .string)
            }
        }

        lastChangeCount = pasteboard.changeCount

        if AppSettings.shared.soundEnabled {
            NSSound(named: "Pop")?.play()
        }
    }

    private func pollPasteboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }

        lastChangeCount = pasteboard.changeCount
        captureCurrentPasteboard()
    }

    private func captureCurrentPasteboard() {
        guard var item = makeItem(from: NSPasteboard.general) else { return }
        guard items.first?.fingerprint != item.fingerprint else { return }

        item.isFavorite = favoriteFingerprints.contains(item.fingerprint)

        items.insert(item, at: 0)
        fetchLinkPreviewIfNeeded(for: item)

        // 超出上限时，优先移除最旧的“非收藏”项，保留收藏
        while items.count > maxItems,
              let index = items.lastIndex(where: { !$0.isFavorite }) {
            items.remove(at: index)
        }

        saveSoon()
    }

    private func makeItem(from pasteboard: NSPasteboard) -> ClipboardItem? {
        let source = NSWorkspace.shared.frontmostApplication
        let sourceName = source?.localizedName ?? "未知应用"
        let sourceBundleIdentifier = source?.bundleIdentifier
        let sourceIcon = source?.icon

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return makeFileItem(
                urls: urls,
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceIcon: sourceIcon
            )
        }

        if let image = NSImage(pasteboard: pasteboard) {
            return makeImageItem(
                image: image,
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceIcon: sourceIcon
            )
        }

        if let urlString = pasteboard.string(forType: .URL), let url = URL(string: urlString) {
            return makeTextItem(
                text: url.absoluteString,
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceIcon: sourceIcon
            )
        }

        if let text = pasteboard.string(forType: .string) {
            return makeTextItem(
                text: text,
                richRTFData: pasteboard.data(forType: .rtf),
                sourceName: sourceName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceIcon: sourceIcon
            )
        }

        return nil
    }

    private func makeImageItem(
        image: NSImage,
        sourceName: String,
        sourceBundleIdentifier: String?,
        sourceIcon: NSImage?
    ) -> ClipboardItem {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let fingerprint = "image:\(width)×\(height):\(image.tiffRepresentation?.count ?? 0)"

        return ClipboardItem(
            kind: .image,
            title: "图片",
            subtitle: "刚刚",
            detail: "\(width) × \(height)",
            rawText: nil,
            image: image,
            fileURLs: [],
            colorHex: nil,
            linkURL: nil,
            previewTitle: nil,
            previewSubtitle: nil,
            previewImage: image,
            sourceAppName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceIcon: sourceIcon,
            createdAt: Date(),
            fingerprint: fingerprint
        )
    }

    private func makeFileItem(
        urls: [URL],
        sourceName: String,
        sourceBundleIdentifier: String?,
        sourceIcon: NSImage?
    ) -> ClipboardItem {
        let first = urls.first?.lastPathComponent ?? "文件"
        let title = urls.count == 1 ? first : "\(urls.count) 个文件"
        let detail = urls.count == 1 ? urls[0].deletingLastPathComponent().path : first
        let fingerprint = "file:" + urls.map(\.path).joined(separator: "|")

        if urls.count == 1,
           let imageURL = urls.first,
           isImageFile(imageURL),
           let preview = NSImage(contentsOf: imageURL) {
            let width = Int(preview.size.width)
            let height = Int(preview.size.height)

            return ClipboardItem(
                kind: .image,
                title: "图片",
                subtitle: "刚刚",
                detail: "\(width) × \(height)",
                rawText: nil,
                image: preview,
                fileURLs: urls,
                colorHex: nil,
                linkURL: nil,
                previewTitle: first,
                previewSubtitle: imageURL.deletingLastPathComponent().path,
                previewImage: preview,
                sourceAppName: sourceName,
                sourceBundleIdentifier: sourceBundleIdentifier,
                sourceIcon: sourceIcon,
                createdAt: Date(),
                fingerprint: fingerprint
            )
        }

        let icon = urls.first.map { NSWorkspace.shared.icon(forFile: $0.path) }

        return ClipboardItem(
            kind: .file,
            title: title,
            subtitle: "刚刚",
            detail: detail,
            rawText: nil,
            image: icon,
            fileURLs: urls,
            colorHex: nil,
            linkURL: nil,
            previewTitle: title,
            previewSubtitle: detail,
            previewImage: icon,
            sourceAppName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceIcon: sourceIcon,
            createdAt: Date(),
            fingerprint: fingerprint
        )
    }

    private func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }

        let ext = url.pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp"].contains(ext)
    }

    private func makeTextItem(
        text: String,
        richRTFData: Data? = nil,
        sourceName: String,
        sourceBundleIdentifier: String?,
        sourceIcon: NSImage?
    ) -> ClipboardItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = classify(text: trimmed)
        let url = kind == .link ? URL(string: trimmed) : nil
        let title = linkTitle(for: url) ?? kind.label
        let detail: String

        switch kind {
        case .link:
            detail = url?.host() ?? "\(trimmed.count) 个字符"
        case .color:
            detail = trimmed.uppercased()
        default:
            detail = "\(trimmed.count) 个字符"
        }

        return ClipboardItem(
            kind: kind,
            title: title,
            subtitle: "刚刚",
            detail: detail,
            rawText: text,
            image: nil,
            fileURLs: [],
            colorHex: kind == .color ? trimmed.uppercased() : nil,
            linkURL: url,
            previewTitle: kind == .link ? title : nil,
            previewSubtitle: kind == .link ? detail : nil,
            previewImage: nil,
            sourceAppName: sourceName,
            sourceBundleIdentifier: sourceBundleIdentifier,
            sourceIcon: sourceIcon,
            createdAt: Date(),
            fingerprint: "\(kind.rawValue):\(text)",
            richRTFData: (kind == .text || kind == .code) ? richRTFData : nil
        )
    }

    private func classify(text: String) -> ClipboardKind {
        if isColor(text) { return .color }
        if isWebURL(text) { return .link }
        if isLikelyCode(text) { return .code }
        return .text
    }

    private func isColor(_ text: String) -> Bool {
        text.range(
            of: #"^#([A-Fa-f0-9]{3}|[A-Fa-f0-9]{6}|[A-Fa-f0-9]{8})$"#,
            options: .regularExpression
        ) != nil
    }

    private func isWebURL(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func isLikelyCode(_ text: String) -> Bool {
        guard text.contains("\n") else { return false }

        let codeSignals = [
            "import ", "func ", "class ", "struct ", "enum ",
            "let ", "var ", "const ", "return ", "public ",
            "{", "}", "=>", "SELECT ", "FROM "
        ]

        let uppercased = text.uppercased()
        return codeSignals.contains { signal in
            signal == signal.uppercased()
                ? uppercased.contains(signal)
                : text.contains(signal)
        }
    }

    private func linkTitle(for url: URL?) -> String? {
        guard let url else { return nil }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !path.isEmpty {
            let components = path.split(separator: "/")
            if components.count >= 2 {
                return components.suffix(2).joined(separator: "/")
            }
            return String(components[0])
        }

        return url.host()
    }

    private func fetchLinkPreviewIfNeeded(for item: ClipboardItem) {
        guard item.kind == .link, let url = item.linkURL else { return }

        let id = item.id
        let provider = LPMetadataProvider()
        provider.startFetchingMetadata(for: url) { [weak self] metadata, _ in
            guard let self, let metadata else { return }

            let title = metadata.title
            let subtitle = url.host()
            let imageProvider = metadata.imageProvider ?? metadata.iconProvider

            Task { @MainActor in
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { return }

                if let title, !title.isEmpty {
                    self.items[index].previewTitle = title
                }

                self.items[index].previewSubtitle = subtitle
                self.saveSoon()
            }

            if let imageProvider {
                imageProvider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard
                        let image = image as? NSImage,
                        let imageData = image.tiffRepresentation
                    else {
                        return
                    }

                    Task { @MainActor in
                        guard
                            let image = NSImage(data: imageData),
                            let imageIndex = self.items.firstIndex(where: { $0.id == id })
                        else {
                            return
                        }

                        self.items[imageIndex].previewImage = image
                    }
                }
            }
        }
    }
}
