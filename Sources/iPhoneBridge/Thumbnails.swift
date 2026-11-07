import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Memory and disk cache, so scrolling back or reopening the library doesn't re-read photos over USB.
@MainActor
final class ThumbnailCache {
    private let memory = NSCache<NSString, NSImage>()
    private let folder: URL

    init(udid: String) {
        folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPhoneBridge/\(udid)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for file: RemoteFile, load: (String) async throws -> Data) async -> NSImage? {
        // Size is part of the key so an edited photo with the same name gets a fresh thumbnail.
        let key = "\(file.size)\(file.path)".replacingOccurrences(of: "/", with: "_")
        if let hit = memory.object(forKey: key as NSString) { return hit }

        let url = folder.appendingPathComponent(key + ".jpg")
        var thumb = try? Data(contentsOf: url)
        if thumb == nil {
            guard let original = try? await load(file.path) else { return nil }
            thumb = try? await offMain { Self.downscale(original) }
            if let thumb { try? thumb.write(to: url) }
        }

        guard let thumb, let image = NSImage(data: thumb) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    nonisolated static func downscale(_ data: Data, maxPixel: Int = 400) -> Data? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honor EXIF rotation
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }
}
