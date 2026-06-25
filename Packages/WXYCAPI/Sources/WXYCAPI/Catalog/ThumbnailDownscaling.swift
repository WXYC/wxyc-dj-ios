//
//  ThumbnailDownscaling.swift
//  WXYCAPI
//
//  The pure Data -> downscaled JPEG transform for on-device Spotlight thumbnails
//  (issue #44). A remote album cover (Discogs/iTunes CDN) is fetched, shrunk to a
//  Spotlight-sized JPEG here, and embedded as CSSearchableItem.thumbnailData. Pure
//  and synchronous — ImageIO runs on the package's macOS slice, so it is
//  host-testable under `swift test`.
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downscales arbitrary image bytes to a small JPEG for embedding as a Spotlight
/// `thumbnailData`. First-party (ImageIO/CoreGraphics) only — no third-party
/// packages, no HEIC (its `CGImageDestination` encoding is broken on the iOS 17.5+
/// Simulator, which would break `swift test`/CI, and its Spotlight rendering is
/// undocumented; once right-sized the byte saving over JPEG is negligible).
public enum ThumbnailDownscaler {
    /// Default longest-side cap, in pixels. 256 px is the Core Spotlight community
    /// convention — crisp on @2x/@3x home-screen results yet only ~13 KB/cover.
    public static let defaultMaxPixelDimension = 256

    /// Downscale `data` to a JPEG whose longest side is at most `maxPixelDimension`,
    /// preserving aspect ratio, at `compressionQuality` (0...1). Returns `nil` if
    /// `data` isn't a decodable image. **Never upscales** — a source already at or
    /// below the cap is re-encoded at its original dimensions (ImageIO's
    /// `kCGImageSourceThumbnailMaxPixelSize` only shrinks).
    public static func downscaledJPEG(
        from data: Data,
        maxPixelDimension: Int = defaultMaxPixelDimension,
        compressionQuality: Double = 0.8
    ) -> Data? {
        // A non-positive cap would make `kCGImageSourceThumbnailMaxPixelSize` mean
        // "no maximum", silently re-encoding at full resolution — fail closed instead.
        guard maxPixelDimension > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }

        let options: [CFString: Any] = [
            // Build from the full image, not an embedded (often tiny) EXIF thumbnail.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            // Apply the source's EXIF orientation so the cached cover isn't rotated.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: compressionQuality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        // A finalize that "succeeds" but yields no bytes must not be treated as a
        // valid thumbnail: caching empty Data writes a zero-byte file that would be
        // served as a permanent cache hit and never re-fetched.
        guard !output.isEmpty else { return nil }
        return output as Data
    }
}
