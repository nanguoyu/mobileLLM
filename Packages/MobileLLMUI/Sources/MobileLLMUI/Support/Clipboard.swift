// SPDX-License-Identifier: MIT

import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform copy-to-clipboard (message + code-block Copy actions).
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }

    /// The clipboard's image as encoded bytes (for paste-into-composer), or `nil` when it holds no image.
    /// The caller downscales/re-encodes before storing — this just hands back the rawest bytes we can.
    static func imageData() -> Data? {
        #if os(iOS)
        let pb = UIPasteboard.general
        if let png = pb.data(forPasteboardType: "public.png") { return png }
        if let jpeg = pb.data(forPasteboardType: "public.jpeg") { return jpeg }
        // Fall back to the decoded UIImage (e.g. a screenshot) re-encoded losslessly to PNG.
        return pb.image?.pngData()
        #elseif os(macOS)
        let pb = NSPasteboard.general
        if let png = pb.data(forType: .png) { return png }
        // TIFF (the common macOS image flavor) → PNG so downstream only handles PNG/JPEG.
        if let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
        #else
        return nil
        #endif
    }
}
