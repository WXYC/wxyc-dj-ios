//
//  ThumbnailDownscalingTests.swift
//  WXYCAPITests
//
//  Tests the pure Data -> downscaled JPEG transform (issue #44): a remote cover
//  is shrunk to a Spotlight-sized thumbnail on-device before being embedded as
//  thumbnailData. Source images are generated via ImageIO so the test is
//  host-runnable under `swift test` (no committed binary, deterministic sizes).
//
//  Created by Jake on 06/24/26.
//  Copyright © 2026 WXYC. All rights reserved.
//

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WXYCAPI

@Suite("ThumbnailDownscaling")
struct ThumbnailDownscalingTests {
    /// A solid-color JPEG of exactly `width` x `height`. JPEG preserves pixel
    /// dimensions regardless of content, so a flat fill is enough to exercise the
    /// resize math while staying tiny.
    static func makeJPEG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The pixel dimensions ImageIO reports for `data`, or `nil` if it isn't an image.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    @Test func downscalesALargeCoverToTheMaxDimensionPreservingAspect() throws {
        // A 600x300 source (longest side 600) capped at 256 -> 256x128.
        let large = Self.makeJPEG(width: 600, height: 300)
        let downscaled = try #require(ThumbnailDownscaler.downscaledJPEG(from: large, maxPixelDimension: 256))
        let size = try #require(Self.pixelSize(of: downscaled))
        #expect(max(size.width, size.height) == 256)
        // Aspect ratio preserved: 600:300 == 2:1 -> 256:128.
        #expect(size.width == 256)
        #expect(size.height == 128)
        // And it actually shrank the payload.
        #expect(downscaled.count < large.count)
    }

    @Test func doesNotUpscaleASourceSmallerThanTheCap() throws {
        // A 100x100 source under a 256 cap must come back at its own size, never
        // enlarged — upscaling would waste bytes and blur the cover.
        let small = Self.makeJPEG(width: 100, height: 100)
        let result = try #require(ThumbnailDownscaler.downscaledJPEG(from: small, maxPixelDimension: 256))
        let size = try #require(Self.pixelSize(of: result))
        #expect(size.width == 100)
        #expect(size.height == 100)
    }

    @Test func returnsNilForUndecodableBytes() {
        // A dirty/unloadable artwork_url's body must resolve to "no thumbnail"
        // (default icon) rather than crashing the lazy cache path.
        #expect(ThumbnailDownscaler.downscaledJPEG(from: Data("not an image".utf8)) == nil)
        #expect(ThumbnailDownscaler.downscaledJPEG(from: Data()) == nil)
    }
}
