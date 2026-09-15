import Foundation
import AppKit
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

/// Image/file format conversion.
///
/// ## Why ImageIO and not a bundled encoder
/// `CGImageDestination` is the same machinery Preview and Finder's Quick Actions
/// use. It handles HEIC, PNG, JPEG, TIFF, GIF and WebP decode natively, is
/// hardware-accelerated on Apple Silicon for HEIC, and costs the app nothing in
/// binary size. Bundling libvips/ImageMagick would add tens of megabytes and a
/// CVE feed to maintain, for worse HEIC support.
///
/// ## Why the work is off the main thread but the API is not `async` all the way
/// Conversion is CPU-bound, not IO-bound, so it runs on a utility queue and hops
/// back to report. Batch conversions are sequential on purpose: converting eight
/// 48MP images in parallel will spike memory into the gigabytes, and this app's
/// entire thesis is that it does not do that.
enum FileConverter {

    struct Target: Identifiable, Hashable {
        var id: String { utType.identifier }
        let name: String
        let utType: UTType
        let fileExtension: String
    }

    static let imageTargets: [Target] = [
        Target(name: "PNG",  utType: .png,  fileExtension: "png"),
        Target(name: "JPEG", utType: .jpeg, fileExtension: "jpg"),
        Target(name: "HEIC", utType: .heic, fileExtension: "heic"),
        Target(name: "TIFF", utType: .tiff, fileExtension: "tiff"),
        Target(name: "GIF",  utType: .gif,  fileExtension: "gif"),
        Target(name: "PDF",  utType: .pdf,  fileExtension: "pdf")
    ]

    /// The longest-edge cap applied before encoding.
    ///
    /// Downscaling is the single biggest lever on output size -- re-encoding a
    /// 48MP photo at 60% quality still leaves a 48MP photo. The presets are the
    /// sizes people actually need: a retina-safe web image, a 1080p-class
    /// asset, a 4K-class one, and untouched.
    struct SizePreset: Identifiable, Hashable {
        var id: String { name }
        let name: String
        /// nil means "leave the pixel dimensions alone".
        let maxPixels: Int?
    }

    static let sizePresets: [SizePreset] = [
        SizePreset(name: "1024px", maxPixels: 1024),
        SizePreset(name: "1920px", maxPixels: 1920),
        SizePreset(name: "2560px", maxPixels: 2560),
        SizePreset(name: "Original", maxPixels: nil)
    ]

    struct Result: Identifiable {
        let id = UUID()
        let sourceName: String
        let outputURL: URL?
        let error: String?
        let originalBytes: Int
        let outputBytes: Int
        /// Small enough to keep in the done-list without holding the full image.
        var thumbnail: NSImage? = nil
        var pixelSize: CGSize? = nil
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Converts sequentially on a utility queue, reporting each result as it
    /// lands so the UI fills in progressively rather than freezing then dumping.
    static func convert(urls: [URL], to target: Target, quality: Double,
                        maxPixels: Int?,
                        progress: @escaping (Result) -> Void,
                        completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                let result = convertOne(url: url, to: target, quality: quality, maxPixels: maxPixels)
                DispatchQueue.main.async { progress(result) }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    private static func convertOne(url: URL, to target: Target, quality: Double, maxPixels: Int?) -> Result {
        let originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Not a readable image", originalBytes: originalBytes, outputBytes: 0)
        }

        // PDF is not a CGImageDestination type in the same way; route it through
        // a single-page PDF context instead of pretending it is a bitmap format.
        if target.utType == .pdf {
            return convertToPDF(source: source, url: url, originalBytes: originalBytes, maxPixels: maxPixels)
        }

        let outputURL = uniqueDestination(for: url, extension: target.fileExtension)
        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL, target.utType.identifier as CFString, 1, nil) else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Cannot write \(target.name)", originalBytes: originalBytes, outputBytes: 0)
        }

        // Preserve orientation/EXIF from the source, then override quality.
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            options[kCGImagePropertyOrientation] = properties[kCGImagePropertyOrientation]
        }

        var finalSize: CGSize?
        if let scaled = downscaled(source: source, maxPixels: maxPixels) {
            // `CreateThumbnailAtIndex` applies the EXIF rotation itself, so the
            // orientation tag must NOT be carried over as well -- doing both
            // rotates the image twice, which is the classic sideways-photo bug.
            options.removeValue(forKey: kCGImagePropertyOrientation)
            CGImageDestinationAddImage(destination, scaled, options as CFDictionary)
            finalSize = CGSize(width: scaled.width, height: scaled.height)
        } else {
            CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
            finalSize = pixelSize(of: source)
        }

        guard CGImageDestinationFinalize(destination) else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Encoding failed", originalBytes: originalBytes, outputBytes: 0)
        }
        let outputBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Result(sourceName: url.lastPathComponent, outputURL: outputURL,
                      error: nil, originalBytes: originalBytes, outputBytes: outputBytes,
                      thumbnail: thumbnail(for: outputURL), pixelSize: finalSize)
    }

    /// Returns a downscaled image, or nil when no downscale is needed.
    ///
    /// `CGImageSourceCreateThumbnailAtIndex` rather than drawing into a smaller
    /// context: it decodes at reduced scale, so a 48MP source never becomes a
    /// 48MP bitmap in memory on the way to being a 1920px one. On a batch of
    /// large photos that is the difference between a few hundred megabytes and
    /// a few gigabytes of peak RSS.
    private static func downscaled(source: CGImageSource, maxPixels: Int?) -> CGImage? {
        guard let maxPixels else { return nil }
        guard let size = pixelSize(of: source) else { return nil }
        let longestEdge = Int(max(size.width, size.height))
        // Never upscale. A preset is a cap, not a target.
        guard longestEdge > maxPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func pixelSize(of source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    /// A small preview of the *output*, so the done-list shows what was actually
    /// produced rather than what went in. Capped at 96px because it is rendered
    /// at 34pt and a batch of forty holds forty of these.
    static func thumbnail(for url: URL, maxPixels: Int = 96) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private static func convertToPDF(source: CGImageSource, url: URL, originalBytes: Int,
                                     maxPixels: Int?) -> Result {
        guard let image = downscaled(source: source, maxPixels: maxPixels)
                ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Cannot decode", originalBytes: originalBytes, outputBytes: 0)
        }
        let outputURL = uniqueDestination(for: url, extension: "pdf")
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(outputURL as CFURL, mediaBox: &box, nil) else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Cannot write PDF", originalBytes: originalBytes, outputBytes: 0)
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        let outputBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Result(sourceName: url.lastPathComponent, outputURL: outputURL,
                      error: nil, originalBytes: originalBytes, outputBytes: outputBytes,
                      thumbnail: thumbnail(for: outputURL),
                      pixelSize: CGSize(width: image.width, height: image.height))
    }

    /// Never silently overwrite. "photo.png", then "photo-1.png", and so on.
    private static func uniqueDestination(for source: URL, extension ext: String) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
