import AppKit
import CryptoKit

extension NSImage {
    /// 生成用于卡片显示的降采样缩略图（最长边 <= maxPixel）。
    /// 卡片只有 ~232pt，没必要在内存里常驻全分辨率位图（4K 截图可达数十 MB）。
    /// 原图始终完整保存在磁盘，粘贴时再按需加载，保真度不受影响。
    func vellumThumbnail(maxPixel: CGFloat = 512) -> NSImage {
        let width = size.width
        let height = size.height
        guard width > 0, height > 0 else { return self }

        let longest = max(width, height)
        guard longest > maxPixel else { return self } // 本来就小，直接用

        let scale = maxPixel / longest
        let target = NSSize(width: floor(width * scale), height: floor(height * scale))

        let thumbnail = NSImage(size: target)
        thumbnail.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        thumbnail.unlockFocus()
        return thumbnail
    }
}

extension Data {
    /// 稳定的内容指纹（跨进程一致），用于图片去重与文件名生成。
    var vellumContentHash: String {
        let digest = SHA256.hash(data: self)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
