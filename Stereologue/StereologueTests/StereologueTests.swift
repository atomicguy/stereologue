//
//  StereologueTests.swift
//  StereologueTests
//
//  Created by Adam Schuster on 7/7/25.
//

import Testing
import Foundation
import CoreGraphics
@testable import Stereologue

struct StereologueTests {

    @Test func restorePreservesDimensionsForEveryStyle() throws {
        let input = try #require(Self.makeTestImage(width: 96, height: 64))
        let pipeline = RestorationPipeline()

        for style in RestorationStyle.allCases {
            let output = pipeline.restore(input, style: style)
            #expect(output.width == input.width, "\(style) changed width")
            #expect(output.height == input.height, "\(style) changed height")
            #expect(!Self.isUniform(output), "\(style) collapsed to a flat color")
        }
    }

    /// Mirrors the real call site (SpatialPhotoService's preparedStereoPair):
    /// the two eyes restored concurrently through `async let` on the shared,
    /// Sendable pipeline.
    @Test func restoreRunsConcurrentlyForBothEyes() async throws {
        let left = try #require(Self.makeTestImage(width: 300, height: 200))
        let right = try #require(Self.makeTestImage(width: 300, height: 200))
        let pipeline = RestorationPipeline()

        async let leftOut = pipeline.restore(left, style: .enhance)
        async let rightOut = pipeline.restore(right, style: .enhance)
        let (l, r) = await (leftOut, rightOut)

        #expect(l.width == left.width)
        #expect(r.width == right.width)
    }

    @Test func matchPairLeavesBalancedPairUntouched() throws {
        let image = try #require(Self.makeTestImage(width: 64, height: 64))
        let pipeline = RestorationPipeline()

        let matched = pipeline.matchPair(left: image, right: image)

        // Identical eyes are already balanced; the pipeline should short-circuit
        // and hand back the very same images rather than re-rendering them.
        #expect(matched.left === image)
        #expect(matched.right === image)
    }

    @Test func variantKeyDistinguishesEveryRenderInput() {
        let base = SpatialPhotoCardData(
            uuid: "abc", frontImageID: "G1",
            leftDetection: ImageDetection(x: 100, y: 200, width: 300, height: 400),
            rightDetection: ImageDetection(x: 500, y: 200, width: 300, height: 400),
            imageWidth: 1000, imageHeight: 500
        )
        let original = SpatialPhotoService.variantKey(for: base, quality: "v", style: nil, deep: false)
        let styled = SpatialPhotoService.variantKey(for: base, quality: "v", style: .enhance, deep: false)
        let deep = SpatialPhotoService.variantKey(for: base, quality: "v", style: .enhance, deep: true)
        let lowRes = SpatialPhotoService.variantKey(for: base, quality: "w", style: nil, deep: false)

        // A user crop edit must never hit the old crop's cache entry.
        var recropped = base
        recropped = SpatialPhotoCardData(
            uuid: base.uuid, frontImageID: base.frontImageID,
            leftDetection: ImageDetection(x: 110, y: 200, width: 300, height: 400),
            rightDetection: base.rightDetection,
            imageWidth: base.imageWidth, imageHeight: base.imageHeight
        )
        let recroppedKey = SpatialPhotoService.variantKey(for: recropped, quality: "v", style: nil, deep: false)

        #expect(Set([original, styled, deep, lowRes, recroppedKey]).count == 5)
        #expect(original == SpatialPhotoService.variantKey(for: base, quality: "v", style: nil, deep: false))
        #expect(original.hasPrefix("abc_"), "evict(cardUUID:) relies on the uuid prefix")
    }

    @Test func parseYearReadsLeadingFourDigits() {
        #expect(StereoCard.parseYear(from: "1871-08") == 1871)
        #expect(StereoCard.parseYear(from: "1850") == 1850)
        #expect(StereoCard.parseYear(from: "ca. 1900") == nil)
        #expect(StereoCard.parseYear(from: "18") == nil)
        #expect(StereoCard.parseYear(from: nil) == nil)
    }

    /// A synthetic noisy gradient — enough structure that a restoration
    /// producing a degenerate (blank/uniform) output is visibly wrong.
    private static func makeTestImage(width: Int, height: Int) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                pixels[i] = UInt8((x * 255) / max(1, width - 1))
                pixels[i + 1] = UInt8((y * 255) / max(1, height - 1))
                pixels[i + 2] = UInt8(((x ^ y) * 37) % 256)
                pixels[i + 3] = 255
            }
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private static func isUniform(_ image: CGImage) -> Bool {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let first = pixels[0]
        return pixels.allSatisfy { $0 == first }
    }
}
