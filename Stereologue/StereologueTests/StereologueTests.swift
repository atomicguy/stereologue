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

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

    @Test func scuNetModelLoadsFromBundle() throws {
        #expect(SCUNetModel.shared != nil)
    }

    @Test func scuNetDenoiserProducesSameSizedImage() throws {
        let model = try #require(SCUNetModel.shared)
        let input = try #require(Self.makeTestImage(width: 96, height: 64))

        let output = SCUNetDenoiser(model: model).apply(to: input)

        #expect(output.width == input.width)
        #expect(output.height == input.height)
        #expect(!Self.isUniform(output), "denoised output should not collapse to a single flat color")
    }

    /// Multi-tile input (900x700 needs several 512x512 tiles with overlap),
    /// called directly and synchronously. Tiles now run strictly one at a
    /// time through SCUNetModel.predictionQueue, so this is expected to take
    /// tens of seconds, not be fast — the time limit exists only to catch a
    /// genuine hang, not to enforce speed.
    @Test(.timeLimit(.minutes(5)))
    func scuNetDenoiserMultiTileDirect() throws {
        let model = try #require(SCUNetModel.shared)
        let input = try #require(Self.makeTestImage(width: 900, height: 700))

        let output = SCUNetDenoiser(model: model).apply(to: input)

        #expect(output.width == input.width)
        #expect(output.height == input.height)
    }

    /// Exactly mirrors the real call site (SpatialPhotoService's
    /// preparedStereoPair): two multi-tile restores kicked off with
    /// `async let` through RestorationPipeline.restore() itself. Both eyes
    /// now serialize behind the same SCUNetModel.predictionQueue, so this
    /// is expected to take roughly as long as the direct test above, twice
    /// over — not fast, just not hung.
    @Test(.timeLimit(.minutes(8)))
    func scuNetDenoiserConcurrentEyesLikeRealCallSite() async throws {
        let left = try #require(Self.makeTestImage(width: 900, height: 700))
        let right = try #require(Self.makeTestImage(width: 900, height: 700))
        let pipeline = RestorationPipeline()

        async let leftOut = pipeline.restore(left, style: .enhance)
        async let rightOut = pipeline.restore(right, style: .enhance)
        let (l, r) = await (leftOut, rightOut)

        #expect(l.width == left.width)
        #expect(r.width == right.width)
    }

    /// A synthetic noisy gradient — enough structure that a denoiser
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
