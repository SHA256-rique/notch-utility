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

    struct Result: Identifiable {
        let id = UUID()
        let sourceName: String
        let outputURL: URL?
        let error: String?
        let originalBytes: Int
        let outputBytes: Int
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// Converts sequentially on a utility queue, reporting each result as it
    /// lands so the UI fills in progressively rather than freezing then dumping.
    static func convert(urls: [URL], to target: Target, quality: Double,
                        progress: @escaping (Result) -> Void,
                        completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for url in urls {
                let result = convertOne(url: url, to: target, quality: quality)
                DispatchQueue.main.async { progress(result) }
            }
            DispatchQueue.main.async { completion() }
        }
    }

    private static func convertOne(url: URL, to target: Target, quality: Double) -> Result {
        let originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Not a readable image", originalBytes: originalBytes, outputBytes: 0)
        }

        // PDF is not a CGImageDestination type in the same way; route it through
        // a single-page PDF context instead of pretending it is a bitmap format.
        if target.utType == .pdf {
            return convertToPDF(source: source, url: url, originalBytes: originalBytes)
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

        CGImageDestinationAddImageFromSource(destination, source, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return Result(sourceName: url.lastPathComponent, outputURL: nil,
                          error: "Encoding failed", originalBytes: originalBytes, outputBytes: 0)
        }
        let outputBytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Result(sourceName: url.lastPathComponent, outputURL: outputURL,
                      error: nil, originalBytes: originalBytes, outputBytes: outputBytes)
    }

    private static func convertToPDF(source: CGImageSource, url: URL, originalBytes: Int) -> Result {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
                      error: nil, originalBytes: originalBytes, outputBytes: outputBytes)
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
