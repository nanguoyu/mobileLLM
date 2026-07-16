// SPDX-License-Identifier: MIT

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Pure image plumbing for chat attachments — decode, downscale, and re-encode to JPEG (DESIGN §2.4 /
/// C2). Built on ImageIO + CoreGraphics (no UIKit/AppKit) so it is cross-platform AND runs in the plain
/// SwiftPM test harness. A picked photo can be 48 MP; we shrink its long edge to `maxLongEdge` and
/// re-encode at `quality` BEFORE it ever rides the prompt or lands on disk, so the model — and the
/// conversation store — only ever see a small, upright JPEG.
enum ImageAttachment {

    /// The long-edge ceiling for a stored attachment (px). ~1568 matches the tile size most on-device
    /// vision projectors sample to, so we neither starve nor waste the encoder.
    static let defaultMaxLongEdge = 1568

    /// JPEG quality for a stored attachment (0…1). 0.8 is visually lossless at this size for a fraction
    /// of the bytes.
    static let defaultQuality = 0.8

    /// Downscale `data` so its long edge is at most `maxLongEdge` and re-encode as JPEG. Never upscales
    /// (a small image comes back at its own size, just re-encoded). EXIF orientation is baked into the
    /// pixels so a portrait photo stays upright. Returns `nil` when `data` isn't a decodable image.
    static func downscaledJPEG(from data: Data,
                               maxLongEdge: Int = defaultMaxLongEdge,
                               quality: Double = defaultQuality) -> Data? {
        guard maxLongEdge > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Respect EXIF orientation so the stored pixels are already upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // A max-pixel-size LARGER than the source returns the source size — ImageIO never upscales.
            kCGImageSourceThumbnailMaxPixelSize: maxLongEdge,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return encodeJPEG(thumbnail, quality: quality)
    }

    /// The pixel dimensions of an encoded image without fully decoding it (for tests + fit checks).
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        let type = UTType.jpeg.identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
