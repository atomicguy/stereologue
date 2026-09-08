import CoreML
import CoreGraphics
import CoreVideo
import Dispatch
import OSLog

/// Runs SCUNet dust/scratch/grain removal over an image at its native
/// resolution, despite the model's fixed 512×512 input, by tiling with
/// overlap and blending tile outputs with a Hann window so seams don't show.
///
/// The image is edge-replicated by half the overlap on every side before
/// tiling. Without that, the true image border would sit exactly on a
/// tile's own edge, where the Hann window is zero — normalizing by zero
/// weight there. Padding moves the border a few pixels into the window's
/// non-zero range; the padding itself is cropped back out after blending.
nonisolated struct SCUNetDenoiser {
    private let model: MLModel
    private let inputName = "image"
    private let outputName = "output"
    private let tileSize = 512
    private let overlap = 64

    private let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "SCUNetDenoiser")

    init(model: MLModel) {
        self.model = model
    }

    func apply(to cgImage: CGImage) -> CGImage {
        guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.imageConstraint else {
            logger.error("SCUNet model missing expected '\(self.inputName, privacy: .public)' image input")
            return cgImage
        }
        guard let padded = PaddedImage(cgImage, pad: overlap / 2, minSize: tileSize) else {
            return cgImage
        }

        let stride = tileSize - overlap
        var accum = [Float](repeating: 0, count: padded.width * padded.height * 3)
        var weight = [Float](repeating: 0, count: padded.width * padded.height)
        let hann = hannWindow(size: tileSize)
        var ranTile = false

        // Tiles run one at a time, deliberately — see the comment on
        // SCUNetModel.predictionQueue. (Genuinely concurrent tile inference
        // via DispatchQueue.concurrentPerform was tried and hung outright
        // rather than speeding anything up.)
        var y = 0
        while true {
            let tileY = min(y, padded.height - tileSize)
            var x = 0
            while true {
                let tileX = min(x, padded.width - tileSize)
                if let tile = padded.tile(x: tileX, y: tileY, size: tileSize),
                   let output = runModel(on: tile, constraint: constraint) {
                    accumulate(
                        output, hann: hann,
                        into: &accum, weight: &weight,
                        originX: tileX, originY: tileY,
                        bufferWidth: padded.width
                    )
                    ranTile = true
                } else {
                    logger.warning("SCUNet tile inference failed at (\(tileX), \(tileY)); skipping tile")
                }
                if tileX + tileSize >= padded.width { break }
                x += stride
            }
            if tileY + tileSize >= padded.height { break }
            y += stride
        }

        guard ranTile, let result = reconstruct(
            accum: accum, weight: weight,
            bufferWidth: padded.width, bufferHeight: padded.height,
            pad: padded.pad, width: cgImage.width, height: cgImage.height,
            colorSpace: cgImage.colorSpace
        ) else { return cgImage }
        return result
    }

    // MARK: - Model Invocation

    /// Runs one 512×512 tile through the model and reads the output back as
    /// normalized (0...1) interleaved RGB.
    private func runModel(on tile: CGImage, constraint: MLImageConstraint) -> (pixels: [Float], width: Int, height: Int)? {
        do {
            let input = try MLFeatureValue(cgImage: tile, constraint: constraint, options: nil)
            let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: input])
            // Serialized app-wide (not just within this call) — see
            // SCUNetModel.predictionQueue. This is what actually protects
            // against the two stereo eyes' concurrent restore() calls both
            // reaching this model at once, not just tiles within one eye.
            let prediction = try SCUNetModel.predictionQueue.sync {
                try model.prediction(from: provider)
            }
            guard let pixelBuffer = prediction.featureValue(for: outputName)?.imageBufferValue else {
                logger.error("SCUNet output missing expected '\(self.outputName, privacy: .public)' image feature")
                return nil
            }
            return readRGB(pixelBuffer)
        } catch {
            logger.error("SCUNet prediction failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Reads a CVPixelBuffer's interleaved BGRA8 (CoreML's standard image
    /// output format) into normalized RGB, discarding alpha.
    private func readRGB(_ pixelBuffer: CVPixelBuffer) -> (pixels: [Float], width: Int, height: Int)? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            logger.error("Unexpected SCUNet output pixel format")
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let src = base.assumingMemoryBound(to: UInt8.self)

        var pixels = [Float](repeating: 0, count: width * height * 3)
        pixels.withUnsafeMutableBufferPointer { out in
            for row in 0..<height {
                let rowBase = row * bytesPerRow
                let outRowBase = row * width * 3
                for col in 0..<width {
                    let s = rowBase + col * 4
                    let o = outRowBase + col * 3
                    out[o] = Float(src[s + 2]) / 255.0     // R
                    out[o + 1] = Float(src[s + 1]) / 255.0 // G
                    out[o + 2] = Float(src[s]) / 255.0     // B
                }
            }
        }
        return (pixels, width, height)
    }

    // MARK: - Hann Window Blending

    /// 2D separable Hann window, flattened row-major.
    private func hannWindow(size: Int) -> [Float] {
        let hann1D = (0..<size).map { i in
            0.5 * (1 - cos(2 * Float.pi * Float(i) / Float(size - 1)))
        }
        var window = [Float](repeating: 0, count: size * size)
        window.withUnsafeMutableBufferPointer { out in
            for row in 0..<size {
                let rowWeight = hann1D[row]
                let base = row * size
                for col in 0..<size {
                    out[base + col] = rowWeight * hann1D[col]
                }
            }
        }
        return window
    }

    private func accumulate(
        _ output: (pixels: [Float], width: Int, height: Int), hann: [Float],
        into accum: inout [Float], weight: inout [Float],
        originX: Int, originY: Int, bufferWidth: Int
    ) {
        guard output.width == tileSize, output.height == tileSize else {
            logger.warning("SCUNet output tile size \(output.width)x\(output.height) != expected \(self.tileSize); skipping")
            return
        }
        output.pixels.withUnsafeBufferPointer { px in
            hann.withUnsafeBufferPointer { hn in
                accum.withUnsafeMutableBufferPointer { acc in
                    weight.withUnsafeMutableBufferPointer { wt in
                        for ly in 0..<tileSize {
                            let gy = originY + ly
                            let localRow = ly * tileSize
                            let globalRow = gy * bufferWidth
                            for lx in 0..<tileSize {
                                let gx = originX + lx
                                let w = hn[localRow + lx]
                                let pSrc = (localRow + lx) * 3
                                let gi = globalRow + gx
                                acc[gi * 3] += w * px[pSrc]
                                acc[gi * 3 + 1] += w * px[pSrc + 1]
                                acc[gi * 3 + 2] += w * px[pSrc + 2]
                                wt[gi] += w
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Reconstruction

    /// Normalizes the accumulator, crops the padding back out, and builds
    /// the final `CGImage`.
    private func reconstruct(
        accum: [Float], weight: [Float],
        bufferWidth: Int, bufferHeight: Int,
        pad: Int, width: Int, height: Int, colorSpace: CGColorSpace?
    ) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        accum.withUnsafeBufferPointer { acc in
            weight.withUnsafeBufferPointer { wt in
                rgba.withUnsafeMutableBufferPointer { out in
                    for row in 0..<height {
                        let srcRow = (row + pad) * bufferWidth
                        let dstRow = row * width
                        for col in 0..<width {
                            let si = srcRow + col + pad
                            let w = wt[si]
                            guard w > 0.0001 else { continue }
                            let di = (dstRow + col) * 4
                            out[di] = clampByte(acc[si * 3] / w)
                            out[di + 1] = clampByte(acc[si * 3 + 1] / w)
                            out[di + 2] = clampByte(acc[si * 3 + 2] / w)
                        }
                    }
                }
            }
        }

        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    private func clampByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value * 255.0))))
    }

    // MARK: - Padded Source Buffer

    /// An RGBA8 buffer edge-replicated outward from `cgImage` by `pad` on
    /// every side, extended further on the right/bottom if needed so both
    /// dimensions reach at least `minSize` (so a single tile always fits).
    private struct PaddedImage {
        let pixels: [UInt8]
        let width: Int
        let height: Int
        let pad: Int

        init?(_ cgImage: CGImage, pad: Int, minSize: Int) {
            let srcWidth = cgImage.width
            let srcHeight = cgImage.height
            guard srcWidth > 0, srcHeight > 0,
                  let source = Self.readRGBA(cgImage) else { return nil }

            self.pad = pad
            width = max(srcWidth + 2 * pad, minSize)
            height = max(srcHeight + 2 * pad, minSize)
            pixels = Self.edgeReplicate(
                source, srcWidth: srcWidth, srcHeight: srcHeight,
                width: width, height: height, pad: pad
            )
        }

        /// Fills a `width`×`height` RGBA8 buffer by sampling `source`
        /// (`srcWidth`×`srcHeight`) with its edge coordinates clamped —
        /// i.e. edge-replication padding. Free function (not a method) so
        /// its closures can't be read as capturing `self` mid-initialization.
        private static func edgeReplicate(
            _ source: [UInt8], srcWidth: Int, srcHeight: Int,
            width: Int, height: Int, pad: Int
        ) -> [UInt8] {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            source.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    for py in 0..<height {
                        let sy = min(max(py - pad, 0), srcHeight - 1)
                        let srcRow = sy * srcWidth
                        let dstRow = py * width
                        for px in 0..<width {
                            let sx = min(max(px - pad, 0), srcWidth - 1)
                            let s = (srcRow + sx) * 4
                            let d = (dstRow + px) * 4
                            dst[d] = src[s]
                            dst[d + 1] = src[s + 1]
                            dst[d + 2] = src[s + 2]
                            dst[d + 3] = src[s + 3]
                        }
                    }
                }
            }
            return out
        }

        /// Extracts a `size`×`size` region starting at `(x, y)`; the caller
        /// is responsible for keeping the region in bounds.
        func tile(x: Int, y: Int, size: Int) -> CGImage? {
            guard x >= 0, y >= 0, x + size <= width, y + size <= height else { return nil }
            var tilePixels = [UInt8](repeating: 0, count: size * size * 4)
            pixels.withUnsafeBufferPointer { src in
                tilePixels.withUnsafeMutableBufferPointer { dst in
                    for row in 0..<size {
                        let srcOffset = ((y + row) * width + x) * 4
                        let dstOffset = row * size * 4
                        for i in 0..<(size * 4) {
                            dst[dstOffset + i] = src[srcOffset + i]
                        }
                    }
                }
            }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let provider = CGDataProvider(data: Data(tilePixels) as CFData) else { return nil }
            return CGImage(
                width: size, height: size,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: size * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )
        }

        private static func readRGBA(_ cgImage: CGImage) -> [UInt8]? {
            let width = cgImage.width
            let height = cgImage.height
            let bytesPerRow = width * 4
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return nil }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = context.data else { return nil }
            return Array(UnsafeBufferPointer(
                start: data.bindMemory(to: UInt8.self, capacity: height * bytesPerRow),
                count: height * bytesPerRow
            ))
        }
    }
}
