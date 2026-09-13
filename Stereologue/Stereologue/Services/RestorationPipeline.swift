import Foundation
import CoreImage
import CoreGraphics
import Metal
import OSLog

/// Distinct restoration intents for scanned stereoview prints.
///
/// These are separate *goals*, not intensity levels of one look:
/// `enhance` maximizes tonal range and neutralizes color casts, `preserveTone`
/// keeps sepia/hand-tinting intact while lifting detail, and `evenLighting`
/// flattens uneven illumination across the print.
enum RestorationStyle: String, CaseIterable, Identifiable, Sendable {
    /// Neutralizes color casts, then maximizes tonal range and local contrast.
    /// Best for faded, low-contrast prints where faithful color doesn't matter.
    case enhance
    /// Lifts luminance and local detail while leaving color untouched, so
    /// sepia toning and hand-tinting survive. Works in a luminance-only domain.
    case preserveTone
    /// Flattens uneven illumination (light leaks, one blown-out side) via
    /// homomorphic filtering, then restores full tonal range.
    case evenLighting

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .enhance: "Enhance"
        case .preserveTone: "Preserve Tone"
        case .evenLighting: "Even Lighting"
        }
    }
}

/// Holds only immutable state (a thread-safe `CIContext` and a `Logger`) and
/// its methods are pure, so it's a `Sendable` class rather than an actor —
/// letting the two eyes of a stereo pair be restored concurrently instead of
/// serializing on an actor executor.
nonisolated final class RestorationPipeline: @unchecked Sendable {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "Restoration"
    )

    private let ciContext: CIContext

    /// An RGBA8 pixel buffer plus the dimensions and color space needed to
    /// round-trip it back to a `CGImage`. CPU stages mutate `pixels` in place
    /// so a whole intent needs only one readback and one writeback.
    private struct Buffer {
        var pixels: [UInt8]
        let width: Int
        let height: Int
        let colorSpace: CGColorSpace?
        var count: Int { width * height }
    }

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingFormat: CIFormat.RGBAh
            ])
        } else {
            ciContext = CIContext()
        }
    }

    // MARK: - Public API

    /// Applies tone/contrast restoration for the given style.
    ///
    /// Tone-only. Dust/scratch repair is a separate, not-yet-shipped track
    /// (see PLAN-fall-2026.md, Phase 3).
    func restore(
        _ cgImage: CGImage,
        style: RestorationStyle = .enhance
    ) -> CGImage {
        let image = ingest(cgImage)
        let result: CGImage?
        switch style {
        case .enhance: result = enhance(image)
        case .preserveTone: result = preserveTone(image)
        case .evenLighting: result = evenLighting(image)
        }

        guard let result else {
            logger.warning("Restoration render failed, returning original")
            return cgImage
        }
        return result
    }

    /// Evens out overall brightness between the two eyes of a stereo pair.
    ///
    /// Matches each eye's luminance mean and spread toward a shared target
    /// (the average of the two) using a single global affine remap per image.
    /// Because the remap is global and monotonic, it only shifts each eye's
    /// tonal envelope — local pixel relationships, and therefore the parallax
    /// depth cues, are untouched. Color is preserved by scaling RGB by the
    /// per-pixel luminance ratio rather than copying values across the pair.
    func matchPair(
        left: CGImage, right: CGImage
    ) -> (left: CGImage, right: CGImage) {
        guard let leftPixels = readRGBA(left),
              let rightPixels = readRGBA(right) else {
            return (left, right)
        }

        let leftStats = luminanceStats(leftPixels)
        let rightStats = luminanceStats(rightPixels)

        // Already balanced — skip the remap (and its two writebacks) entirely.
        if abs(leftStats.mean - rightStats.mean) < 0.02
            && abs(leftStats.std - rightStats.std) < 0.02 {
            return (left, right)
        }

        // Choose the target tonal envelope. When one eye is meaningfully more
        // blown out than the other, match toward the *better-exposed* (less
        // clipped) eye rather than the midpoint — pulling both toward an average
        // would drag the good eye toward the blown one. When clipping is
        // comparable, fall back to the symmetric average.
        let leftClip = clipFraction(leftPixels)
        let rightClip = clipFraction(rightPixels)
        let targetMean: Float
        let targetStd: Float
        if abs(leftClip - rightClip) > 0.01 {
            let reference = leftClip <= rightClip ? leftStats : rightStats
            targetMean = reference.mean
            targetStd = reference.std
        } else {
            targetMean = (leftStats.mean + rightStats.mean) / 2
            targetStd = (leftStats.std + rightStats.std) / 2
        }

        let newLeft = applyLuminanceAffine(
            left, pixels: leftPixels,
            sourceMean: leftStats.mean, sourceStd: leftStats.std,
            targetMean: targetMean, targetStd: targetStd
        ) ?? left
        let newRight = applyLuminanceAffine(
            right, pixels: rightPixels,
            sourceMean: rightStats.mean, sourceStd: rightStats.std,
            targetMean: targetMean, targetStd: targetStd
        ) ?? right

        return (newLeft, newRight)
    }

    // MARK: - Intents
    //
    // Each intent reads the pixels once, runs its CPU stages in place on that
    // single buffer, then writes back once. The only GPU excursions are the
    // Core Image color/tone filters (`neutralizeSepia`, `applyToneCurve`).

    /// Neutralize color cast, stretch tonal range robustly, then boost local
    /// contrast. The per-channel stretch doubles as a rough white balance.
    private func enhance(_ image: CIImage) -> CGImage? {
        guard var buffer = read(image) else { return nil }
        // Data-driven white balance (shades-of-gray) neutralizes whatever color
        // cast the print has, without the old fixed sepia curve's assumption
        // about which cast it is.
        autoWhiteBalance(&buffer.pixels, count: buffer.count)
        percentileStretchPerChannel(&buffer.pixels, count: buffer.count, lowPct: 0.01, highPct: 0.99)
        // Correct globally faded/dark or over-bright scans toward a mid-tone
        // target (color-preserving gamma).
        autoExposure(&buffer.pixels, count: buffer.count)
        var clahe = CLAHEProcessor()
        clahe.tileSize = 128
        clahe.clipLimit = 2.0
        clahe.apply(to: &buffer.pixels, width: buffer.width, height: buffer.height)
        guard let stretched = makeRGBA(
            buffer.pixels, width: buffer.width, height: buffer.height,
            colorSpace: buffer.colorSpace
        ) else { return nil }
        let toned = applyToneCurve(CIImage(cgImage: stretched))
        return ciContext.createCGImage(toned, from: toned.extent)
    }

    /// Luminance-only enhancement. Every stage here (luminance stretch, CLAHE)
    /// scales RGB by a luminance *ratio*, so hue and saturation — including
    /// sepia and hand-tinting — pass through unchanged. No cast neutralization.
    private func preserveTone(_ image: CIImage) -> CGImage? {
        guard var buffer = read(image) else { return nil }
        percentileStretchLuminance(&buffer.pixels, count: buffer.count, lowPct: 0.01, highPct: 0.99)
        // Color-preserving auto-exposure, so faded prints are lifted while
        // sepia/hand-tinting stays intact.
        autoExposure(&buffer.pixels, count: buffer.count)
        var clahe = CLAHEProcessor()
        clahe.tileSize = 160
        clahe.clipLimit = 1.6
        clahe.apply(to: &buffer.pixels, width: buffer.width, height: buffer.height)
        return makeRGBA(
            buffer.pixels, width: buffer.width, height: buffer.height,
            colorSpace: buffer.colorSpace
        )
    }

    /// Flatten uneven illumination with a homomorphic filter, then restore
    /// full tonal range. Color is preserved (luminance-ratio scaling).
    private func evenLighting(_ image: CIImage) -> CGImage? {
        guard var buffer = read(image) else { return nil }
        homomorphic(
            &buffer.pixels, width: buffer.width, height: buffer.height,
            lowGain: 0.5, highGain: 1.6, blurFraction: 0.08
        )
        percentileStretchLuminance(&buffer.pixels, count: buffer.count, lowPct: 0.005, highPct: 0.995)
        return makeRGBA(
            buffer.pixels, width: buffer.width, height: buffer.height,
            colorSpace: buffer.colorSpace
        )
    }

    // MARK: - Stage: Ingest

    private func ingest(_ cgImage: CGImage) -> CIImage {
        let sourceSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIImage(cgImage: cgImage, options: [.colorSpace: sourceSpace])
    }

    /// Renders a CIImage to a CPU pixel buffer (the single readback per intent).
    private func read(_ image: CIImage) -> Buffer? {
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let pixels = readRGBA(cg) else {
            return nil
        }
        return Buffer(pixels: pixels, width: cg.width, height: cg.height, colorSpace: cg.colorSpace)
    }

    // MARK: - Stage: Auto White Balance

    /// Shades-of-gray (Minkowski p=6) white balance: estimate the illuminant
    /// from the p-norm mean of each channel, then scale channels so that
    /// estimate goes neutral. More robust than plain gray-world on scenes with a
    /// dominant color, and — unlike a fixed sepia curve — it adapts to whatever
    /// cast the individual print actually has. Gains are clamped and a near-unit
    /// correction is skipped, so it's a no-op on already-neutral images.
    private func autoWhiteBalance(_ pixels: inout [UInt8], count: Int) {
        guard count > 0 else { return }
        let p = 6.0
        let stride = analysisStride(count)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var samples = 0
        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                sumR += pow(Double(src[base]) / 255.0, p)
                sumG += pow(Double(src[base + 1]) / 255.0, p)
                sumB += pow(Double(src[base + 2]) / 255.0, p)
                samples += 1
                i += stride
            }
        }
        guard samples > 0 else { return }
        let meanR = Float(pow(sumR / Double(samples), 1.0 / p))
        let meanG = Float(pow(sumG / Double(samples), 1.0 / p))
        let meanB = Float(pow(sumB / Double(samples), 1.0 / p))
        guard meanR > 0.001, meanG > 0.001, meanB > 0.001 else { return }

        let gray = (meanR + meanG + meanB) / 3
        let gainR = min(max(gray / meanR, 0.5), 2.0)
        let gainG = min(max(gray / meanG, 0.5), 2.0)
        let gainB = min(max(gray / meanB, 0.5), 2.0)

        // Already neutral — skip the writeback.
        if abs(gainR - 1) < 0.03 && abs(gainG - 1) < 0.03 && abs(gainB - 1) < 0.03 {
            return
        }

        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<count {
                let base = i * 4
                out[base] = clampNormalizedByte(Float(out[base]) / 255.0 * gainR)
                out[base + 1] = clampNormalizedByte(Float(out[base + 1]) / 255.0 * gainG)
                out[base + 2] = clampNormalizedByte(Float(out[base + 2]) / 255.0 * gainB)
            }
        }
    }

    // MARK: - Stage: Auto Exposure

    /// Color-preserving auto-exposure. Nudges the image's mean luminance toward
    /// a mid-tone target with a global gamma, scaling RGB by the luminance ratio
    /// so hue/saturation are untouched. Gamma is clamped and near-unit
    /// corrections are skipped, so a well-exposed image passes through unchanged.
    private func autoExposure(_ pixels: inout [UInt8], count: Int, target: Float = 0.5) {
        guard count > 0 else { return }
        let stride = analysisStride(count)
        var sum: Float = 0
        var samples = 0
        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                sum += 0.2126 * Float(src[base]) / 255.0
                    + 0.7152 * Float(src[base + 1]) / 255.0
                    + 0.0722 * Float(src[base + 2]) / 255.0
                samples += 1
                i += stride
            }
        }
        guard samples > 0 else { return }
        let mean = sum / Float(samples)
        guard mean > 0.02, mean < 0.98 else { return }

        var gamma = log(target) / log(mean)
        gamma = min(max(gamma, 0.5), 2.0)
        if abs(gamma - 1) < 0.05 { return }

        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<count {
                let base = i * 4
                let r = Float(out[base]) / 255.0
                let g = Float(out[base + 1]) / 255.0
                let b = Float(out[base + 2]) / 255.0
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                guard l > 0.001 else { continue }
                let ratio = pow(l, gamma) / l
                out[base] = clampNormalizedByte(r * ratio)
                out[base + 1] = clampNormalizedByte(g * ratio)
                out[base + 2] = clampNormalizedByte(b * ratio)
            }
        }
    }

    // MARK: - Stage: Percentile Contrast Stretch

    /// Independent per-channel percentile stretch. Equalizes the R/G/B ranges,
    /// which also neutralizes color casts. Histograms are built from a strided
    /// sample; the resulting 256-entry LUTs are applied to every pixel.
    private func percentileStretchPerChannel(
        _ pixels: inout [UInt8], count: Int, lowPct: Float, highPct: Float
    ) {
        guard count > 0 else { return }
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)
        let stride = analysisStride(count)
        var samples = 0

        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                histR[Int(src[base])] += 1
                histG[Int(src[base + 1])] += 1
                histB[Int(src[base + 2])] += 1
                samples += 1
                i += stride
            }
        }

        let mapR = channelMap(histogram: histR, total: samples, lowPct: lowPct, highPct: highPct)
        let mapG = channelMap(histogram: histG, total: samples, lowPct: lowPct, highPct: highPct)
        let mapB = channelMap(histogram: histB, total: samples, lowPct: lowPct, highPct: highPct)

        mapR.withUnsafeBufferPointer { r in
        mapG.withUnsafeBufferPointer { g in
        mapB.withUnsafeBufferPointer { b in
            pixels.withUnsafeMutableBufferPointer { out in
                for i in 0..<count {
                    let base = i * 4
                    out[base] = r[Int(out[base])]
                    out[base + 1] = g[Int(out[base + 1])]
                    out[base + 2] = b[Int(out[base + 2])]
                }
            }
        }}}
    }

    /// Single stretch derived from a luminance histogram, applied as an RGB
    /// ratio so color is preserved. Used by the color-preserving intents.
    private func percentileStretchLuminance(
        _ pixels: inout [UInt8], count: Int, lowPct: Float, highPct: Float
    ) {
        guard count > 0 else { return }
        var hist = [Int](repeating: 0, count: 256)
        let stride = analysisStride(count)
        var samples = 0

        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                let r = Float(src[base]) / 255.0
                let g = Float(src[base + 1]) / 255.0
                let b = Float(src[base + 2]) / 255.0
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                hist[min(255, max(0, Int(l * 255.0)))] += 1
                samples += 1
                i += stride
            }
        }

        let low = percentile(histogram: hist, total: samples, fraction: lowPct)
        let high = percentile(histogram: hist, total: samples, fraction: highPct)
        let range = high - low
        guard range > 0.02 else { return }
        let scale = 1.0 / range

        pixels.withUnsafeMutableBufferPointer { out in
            for i in 0..<count {
                let base = i * 4
                let r = Float(out[base]) / 255.0
                let g = Float(out[base + 1]) / 255.0
                let b = Float(out[base + 2]) / 255.0
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                let newL = min(1, max(0, (l - low) * scale))
                if l > 0.001 {
                    let ratio = newL / l
                    out[base] = clampNormalizedByte(r * ratio)
                    out[base + 1] = clampNormalizedByte(g * ratio)
                    out[base + 2] = clampNormalizedByte(b * ratio)
                } else {
                    let mapped = clampNormalizedByte(newL)
                    out[base] = mapped
                    out[base + 1] = mapped
                    out[base + 2] = mapped
                }
            }
        }
    }

    /// Builds a 256-entry lookup table mapping each input byte to its
    /// percentile-stretched value for one channel.
    private func channelMap(
        histogram: [Int], total: Int, lowPct: Float, highPct: Float
    ) -> [UInt8] {
        let low = percentile(histogram: histogram, total: total, fraction: lowPct)
        let high = percentile(histogram: histogram, total: total, fraction: highPct)
        let range = high - low
        guard range > 0.02 else {
            return (0...255).map { UInt8($0) }
        }
        let scale = 1.0 / range
        return (0...255).map { value in
            clampNormalizedByte((Float(value) / 255.0 - low) * scale)
        }
    }

    /// Returns the normalized (0...1) value at the given cumulative fraction
    /// of a histogram.
    private func percentile(histogram: [Int], total: Int, fraction: Float) -> Float {
        guard total > 0 else { return 0 }
        let threshold = Int(Float(total) * fraction)
        var cumulative = 0
        for bin in 0..<histogram.count {
            cumulative += histogram[bin]
            if cumulative >= threshold {
                return Float(bin) / Float(histogram.count - 1)
            }
        }
        return 1
    }

    // MARK: - Stage: Homomorphic Filter

    /// Homomorphic filtering: in the log-luminance domain, attenuate the
    /// low-frequency component (illumination — the source of uneven brightness
    /// and blown-out patches) and amplify the high-frequency component
    /// (reflectance — the actual scene detail). Color is preserved by scaling
    /// RGB by the resulting luminance ratio.
    ///
    /// The illumination field is estimated entirely on the CPU: block-average
    /// the log-luminance into a small grid, smooth it, then bilinearly upsample
    /// per pixel — avoiding a full-resolution Gaussian blur and its readback.
    private func homomorphic(
        _ pixels: inout [UInt8], width: Int, height: Int,
        lowGain: Float, highGain: Float, blurFraction: Float
    ) {
        let count = width * height
        guard count > 0 else { return }
        let eps: Float = 0.01

        var luma = [Float](repeating: 0, count: count)
        var logL = [Float](repeating: 0, count: count)
        pixels.withUnsafeBufferPointer { src in
            luma.withUnsafeMutableBufferPointer { lm in
                logL.withUnsafeMutableBufferPointer { lg in
                    for i in 0..<count {
                        let base = i * 4
                        let r = Float(src[base]) / 255.0
                        let g = Float(src[base + 1]) / 255.0
                        let b = Float(src[base + 2]) / 255.0
                        let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                        lm[i] = l
                        lg[i] = log(l + eps)
                    }
                }
            }
        }

        // Estimate illumination: block-average log-luminance into a small grid.
        let cell = max(8, Int(Double(min(width, height)) * Double(blurFraction)))
        let fieldW = max(1, (width + cell - 1) / cell)
        let fieldH = max(1, (height + cell - 1) / cell)
        var field = [Float](repeating: 0, count: fieldW * fieldH)
        var counts = [Int](repeating: 0, count: fieldW * fieldH)
        logL.withUnsafeBufferPointer { lg in
            for y in 0..<height {
                let fy = min(fieldH - 1, y / cell)
                let rowBase = y * width
                let fieldRow = fy * fieldW
                for x in 0..<width {
                    let fx = min(fieldW - 1, x / cell)
                    let fi = fieldRow + fx
                    field[fi] += lg[rowBase + x]
                    counts[fi] += 1
                }
            }
        }
        for i in 0..<field.count where counts[i] > 0 { field[i] /= Float(counts[i]) }
        field = smoothField(field, width: fieldW, height: fieldH)

        // Apply, bilinearly upsampling the illumination field (cell centers).
        let halfCell = Float(cell) / 2
        pixels.withUnsafeMutableBufferPointer { out in
            luma.withUnsafeBufferPointer { lm in
            logL.withUnsafeBufferPointer { lg in
            field.withUnsafeBufferPointer { fld in
                for y in 0..<height {
                    let gy = (Float(y) - halfCell + 0.5) / Float(cell)
                    let gy0 = max(0, min(fieldH - 1, Int(floor(gy))))
                    let gy1 = max(0, min(fieldH - 1, gy0 + 1))
                    let wy = max(0, min(1, gy - Float(gy0)))
                    let rowBase = y * width
                    for x in 0..<width {
                        let gx = (Float(x) - halfCell + 0.5) / Float(cell)
                        let gx0 = max(0, min(fieldW - 1, Int(floor(gx))))
                        let gx1 = max(0, min(fieldW - 1, gx0 + 1))
                        let wx = max(0, min(1, gx - Float(gx0)))

                        let f00 = fld[gy0 * fieldW + gx0]
                        let f01 = fld[gy0 * fieldW + gx1]
                        let f10 = fld[gy1 * fieldW + gx0]
                        let f11 = fld[gy1 * fieldW + gx1]
                        let top = f00 * (1 - wx) + f01 * wx
                        let bottom = f10 * (1 - wx) + f11 * wx
                        let low = top * (1 - wy) + bottom * wy

                        let idx = rowBase + x
                        let high = lg[idx] - low
                        let newLog = lowGain * low + highGain * high
                        let newL = max(0, exp(newLog) - eps)
                        let l = lm[idx]
                        let base = idx * 4
                        if l > 0.001 {
                            let ratio = newL / l
                            out[base] = clampNormalizedByte(Float(out[base]) / 255.0 * ratio)
                            out[base + 1] = clampNormalizedByte(Float(out[base + 1]) / 255.0 * ratio)
                            out[base + 2] = clampNormalizedByte(Float(out[base + 2]) / 255.0 * ratio)
                        } else {
                            let mapped = clampNormalizedByte(newL)
                            out[base] = mapped
                            out[base + 1] = mapped
                            out[base + 2] = mapped
                        }
                    }
                }
            }}}
        }
    }

    /// A single separable 1-2-1 pass to take the blockiness off the downsampled
    /// illumination field.
    private func smoothField(_ field: [Float], width: Int, height: Int) -> [Float] {
        guard width > 2, height > 2 else { return field }
        var temp = field
        field.withUnsafeBufferPointer { src in
            temp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let base = y * width
                    for x in 0..<width {
                        let x0 = max(0, x - 1)
                        let x1 = min(width - 1, x + 1)
                        dst[base + x] = (src[base + x0] + 2 * src[base + x] + src[base + x1]) / 4
                    }
                }
            }
        }
        var result = field
        temp.withUnsafeBufferPointer { src in
            result.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let y0 = max(0, y - 1) * width
                    let y1 = min(height - 1, y + 1) * width
                    let base = y * width
                    for x in 0..<width {
                        dst[base + x] = (src[y0 + x] + 2 * src[base + x] + src[y1 + x]) / 4
                    }
                }
            }
        }
        return result
    }

    // MARK: - Stage: Global Tone Curve

    private func applyToneCurve(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIToneCurve") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0.0, y: 0.0), forKey: "inputPoint0")
        filter.setValue(CIVector(x: 0.25, y: 0.20), forKey: "inputPoint1")
        filter.setValue(CIVector(x: 0.50, y: 0.50), forKey: "inputPoint2")
        filter.setValue(CIVector(x: 0.75, y: 0.80), forKey: "inputPoint3")
        filter.setValue(CIVector(x: 1.0, y: 1.0), forKey: "inputPoint4")
        return filter.outputImage ?? image
    }

    // MARK: - Luminance Statistics

    /// Mean and standard deviation of Rec. 709 luminance across a strided
    /// sample of an RGBA buffer.
    private func luminanceStats(_ pixels: [UInt8]) -> (mean: Float, std: Float) {
        let count = pixels.count / 4
        guard count > 0 else { return (0, 0) }
        let stride = analysisStride(count)
        var sum: Float = 0
        var sumSq: Float = 0
        var samples = 0
        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                let r = Float(src[base]) / 255.0
                let g = Float(src[base + 1]) / 255.0
                let b = Float(src[base + 2]) / 255.0
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                sum += l
                sumSq += l * l
                samples += 1
                i += stride
            }
        }
        let mean = sum / Float(samples)
        let variance = max(0, sumSq / Float(samples) - mean * mean)
        return (mean, variance.squareRoot())
    }

    /// Fraction of pixels whose luminance is at or above the near-clipping
    /// threshold (0.97), across a strided sample. A rough "how blown out is this
    /// eye" measure used to pick the exposure-match reference.
    private func clipFraction(_ pixels: [UInt8]) -> Float {
        let count = pixels.count / 4
        guard count > 0 else { return 0 }
        let stride = analysisStride(count)
        var clipped = 0
        var samples = 0
        pixels.withUnsafeBufferPointer { src in
            var i = 0
            while i < count {
                let base = i * 4
                let r = Float(src[base]) / 255.0
                let g = Float(src[base + 1]) / 255.0
                let b = Float(src[base + 2]) / 255.0
                let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                if l >= 0.97 { clipped += 1 }
                samples += 1
                i += stride
            }
        }
        return samples > 0 ? Float(clipped) / Float(samples) : 0
    }

    /// Remaps one image's luminance via `(l - sourceMean) * gain + targetMean`,
    /// preserving color by scaling RGB by the luminance ratio.
    private func applyLuminanceAffine(
        _ cgImage: CGImage, pixels: [UInt8],
        sourceMean: Float, sourceStd: Float,
        targetMean: Float, targetStd: Float
    ) -> CGImage? {
        let count = pixels.count / 4
        guard count > 0 else { return cgImage }
        let gain = sourceStd > 0.001 ? targetStd / sourceStd : 1.0

        var output = [UInt8](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { out in
                for i in 0..<count {
                    let base = i * 4
                    let r = Float(src[base]) / 255.0
                    let g = Float(src[base + 1]) / 255.0
                    let b = Float(src[base + 2]) / 255.0
                    let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    let newL = min(1, max(0, (l - sourceMean) * gain + targetMean))
                    if l > 0.001 {
                        let ratio = newL / l
                        out[base] = clampNormalizedByte(r * ratio)
                        out[base + 1] = clampNormalizedByte(g * ratio)
                        out[base + 2] = clampNormalizedByte(b * ratio)
                    } else {
                        let mapped = clampNormalizedByte(newL)
                        out[base] = mapped
                        out[base + 1] = mapped
                        out[base + 2] = mapped
                    }
                    out[base + 3] = src[base + 3]
                }
            }
        }

        return makeRGBA(
            output, width: cgImage.width, height: cgImage.height,
            colorSpace: cgImage.colorSpace
        )
    }

    // MARK: - Pixel Helpers

    /// Number of pixels to skip between samples when only image statistics are
    /// needed. Caps analysis passes at ~300k samples regardless of resolution.
    private func analysisStride(_ count: Int) -> Int {
        max(1, count / 300_000)
    }

    private func readRGBA(_ cgImage: CGImage) -> [UInt8]? {
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

    private func makeRGBA(
        _ pixels: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace?
    ) -> CGImage? {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else {
            return nil
        }
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

    private func clampNormalizedByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value * 255.0))))
    }
}
