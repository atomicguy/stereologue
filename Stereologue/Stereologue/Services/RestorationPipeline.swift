import Foundation
import Accelerate
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

/// Tone and contrast restoration for scanned prints.
///
/// Holds only immutable state (a thread-safe `CIContext` and a `Logger`) and
/// its methods are pure, so it's a `Sendable` class rather than an actor —
/// letting the two eyes of a stereo pair be restored concurrently instead of
/// serializing on an actor executor.
///
/// Every stage works on `PixelPlanes` (planar Float32 RGB) with vDSP/vImage/
/// vForce calls, never a per-pixel Swift loop, so it runs at library speed in
/// Debug builds as well as Release. Color is preserved throughout by scaling
/// RGB by a per-pixel luminance ratio rather than editing channels.
nonisolated final class RestorationPipeline: @unchecked Sendable {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "Restoration"
    )

    private let ciContext: CIContext

    /// The working image: planar float RGB plus the color space needed to
    /// round-trip it back to a `CGImage`.
    private struct Buffer {
        var planes: PixelPlanes
        let colorSpace: CGColorSpace?
        var width: Int { planes.width }
        var height: Int { planes.height }
        var count: Int { planes.count }
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
        restoreTimed(cgImage, style: style).image
    }

    /// Wall-clock duration of one pipeline stage. Produced by `restoreTimed`
    /// for profiling; the stage names are the private method names.
    struct StageTiming: Sendable {
        let stage: String
        let duration: Duration
    }

    /// `restore`, plus how long each stage took. Timing cost is a clock read
    /// per stage, so `restore` simply calls this and drops the timings.
    func restoreTimed(
        _ cgImage: CGImage,
        style: RestorationStyle
    ) -> (image: CGImage, timings: [StageTiming]) {
        var timings: [StageTiming] = []
        let clock = ContinuousClock()
        let timer: StageTimer = { name, body in
            let start = clock.now
            body()
            timings.append(StageTiming(stage: name, duration: clock.now - start))
        }

        let image = ingest(cgImage)
        let result: CGImage?
        switch style {
        case .enhance: result = enhance(image, timer)
        case .preserveTone: result = preserveTone(image, timer)
        case .evenLighting: result = evenLighting(image, timer)
        }

        guard let result else {
            logger.warning("Restoration render failed, returning original")
            return (cgImage, timings)
        }
        return (result, timings)
    }

    private typealias StageTimer = (_ stage: String, _ body: () -> Void) -> Void

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
        guard let leftPixels = readPlanes(left),
              let rightPixels = readPlanes(right) else {
            return (left, right)
        }
        let leftLum = leftPixels.luminance()
        let rightLum = rightPixels.luminance()
        let leftStats = luminanceStats(leftLum)
        let rightStats = luminanceStats(rightLum)

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
        let leftClip = Vec.fraction(of: leftLum, atLeast: 0.97, stride: analysisStride(leftLum.count))
        let rightClip = Vec.fraction(of: rightLum, atLeast: 0.97, stride: analysisStride(rightLum.count))
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
            left, planes: leftPixels, luminance: leftLum,
            sourceMean: leftStats.mean, sourceStd: leftStats.std,
            targetMean: targetMean, targetStd: targetStd
        ) ?? left
        let newRight = applyLuminanceAffine(
            right, planes: rightPixels, luminance: rightLum,
            sourceMean: rightStats.mean, sourceStd: rightStats.std,
            targetMean: targetMean, targetStd: targetStd
        ) ?? right

        return (newLeft, newRight)
    }

    // MARK: - Intents
    //
    // Each intent reads the pixels once, runs its stages on the planar float
    // buffer, then writes back once. The only GPU excursion is the Core Image
    // tone curve at the end of `enhance`.

    /// Neutralize color cast, stretch tonal range robustly, then boost local
    /// contrast. The per-channel stretch doubles as a rough white balance.
    private func enhance(_ image: CIImage, _ time: StageTimer) -> CGImage? {
        var read: Buffer?
        time("read") { read = self.read(image) }
        guard var buffer = read else { return nil }
        // Data-driven white balance (shades-of-gray) neutralizes whatever color
        // cast the print has, without the old fixed sepia curve's assumption
        // about which cast it is.
        time("autoWhiteBalance") { autoWhiteBalance(&buffer.planes) }
        time("percentileStretchPerChannel") {
            percentileStretchPerChannel(&buffer.planes, lowPct: 0.01, highPct: 0.99)
        }
        // Correct globally faded/dark or over-bright scans toward a mid-tone
        // target (color-preserving gamma).
        time("autoExposure") { autoExposure(&buffer.planes) }
        time("clahe") {
            var clahe = CLAHEProcessor()
            clahe.tileSize = 128
            clahe.clipLimit = 2.0
            applyCLAHE(clahe, to: &buffer.planes)
        }
        var stretched: CGImage?
        time("makeRGBA") { stretched = makeImage(buffer) }
        guard let stretched else { return nil }
        var output: CGImage?
        time("toneCurve") {
            let toned = applyToneCurve(CIImage(cgImage: stretched))
            output = ciContext.createCGImage(toned, from: toned.extent)
        }
        return output
    }

    /// Luminance-only enhancement. Every stage here (luminance stretch, CLAHE)
    /// scales RGB by a luminance *ratio*, so hue and saturation — including
    /// sepia and hand-tinting — pass through unchanged. No cast neutralization.
    private func preserveTone(_ image: CIImage, _ time: StageTimer) -> CGImage? {
        var read: Buffer?
        time("read") { read = self.read(image) }
        guard var buffer = read else { return nil }
        time("percentileStretchLuminance") {
            percentileStretchLuminance(&buffer.planes, lowPct: 0.01, highPct: 0.99)
        }
        // Color-preserving auto-exposure, so faded prints are lifted while
        // sepia/hand-tinting stays intact.
        time("autoExposure") { autoExposure(&buffer.planes) }
        time("clahe") {
            var clahe = CLAHEProcessor()
            clahe.tileSize = 160
            clahe.clipLimit = 1.6
            applyCLAHE(clahe, to: &buffer.planes)
        }
        var output: CGImage?
        time("makeRGBA") { output = makeImage(buffer) }
        return output
    }

    /// Flatten uneven illumination with a homomorphic filter, then restore
    /// full tonal range. Color is preserved (luminance-ratio scaling).
    private func evenLighting(_ image: CIImage, _ time: StageTimer) -> CGImage? {
        var read: Buffer?
        time("read") { read = self.read(image) }
        guard var buffer = read else { return nil }
        time("homomorphic") {
            homomorphic(&buffer.planes, lowGain: 0.5, highGain: 1.6, blurFraction: 0.08)
        }
        time("percentileStretchLuminance") {
            percentileStretchLuminance(&buffer.planes, lowPct: 0.005, highPct: 0.995)
        }
        var output: CGImage?
        time("makeRGBA") { output = makeImage(buffer) }
        return output
    }

    // MARK: - Stage: Ingest / Readback

    private func ingest(_ cgImage: CGImage) -> CIImage {
        let sourceSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIImage(cgImage: cgImage, options: [.colorSpace: sourceSpace])
    }

    /// Renders a CIImage to the planar working buffer (the single readback
    /// per intent).
    private func read(_ image: CIImage) -> Buffer? {
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let planes = readPlanes(cg) else {
            return nil
        }
        return Buffer(planes: planes, colorSpace: cg.colorSpace)
    }

    private func makeImage(_ buffer: Buffer) -> CGImage? {
        makeRGBA(buffer.planes.rgba(), width: buffer.width, height: buffer.height, colorSpace: buffer.colorSpace)
    }

    // MARK: - Stage: Auto White Balance

    /// Shades-of-gray (Minkowski p=6) white balance: estimate the illuminant
    /// from the p-norm mean of each channel, then scale channels so that
    /// estimate goes neutral. More robust than plain gray-world on scenes with a
    /// dominant color, and — unlike a fixed sepia curve — it adapts to whatever
    /// cast the individual print actually has. Gains are clamped and a near-unit
    /// correction is skipped, so it's a no-op on already-neutral images.
    private func autoWhiteBalance(_ planes: inout PixelPlanes) {
        guard planes.count > 0 else { return }
        let p: Float = 6
        let stride = analysisStride(planes.count)
        func pNormMean(_ channel: [Float]) -> Float {
            Foundation.pow(Vec.mean(Vec.pow(Vec.sampled(channel, stride: stride), p)), 1 / p)
        }
        let meanR = pNormMean(planes.r)
        let meanG = pNormMean(planes.g)
        let meanB = pNormMean(planes.b)
        guard meanR > 0.001, meanG > 0.001, meanB > 0.001 else { return }

        let gray = (meanR + meanG + meanB) / 3
        let gainR = min(max(gray / meanR, 0.5), 2.0)
        let gainG = min(max(gray / meanG, 0.5), 2.0)
        let gainB = min(max(gray / meanB, 0.5), 2.0)

        // Already neutral — skip the writeback.
        if abs(gainR - 1) < 0.03 && abs(gainG - 1) < 0.03 && abs(gainB - 1) < 0.03 {
            return
        }
        planes.multiply(r: gainR, g: gainG, b: gainB)
    }

    // MARK: - Stage: Auto Exposure

    /// Color-preserving auto-exposure. Nudges the image's mean luminance toward
    /// a mid-tone target with a global gamma, scaling RGB by the luminance ratio
    /// so hue/saturation are untouched. Gamma is clamped and near-unit
    /// corrections are skipped, so a well-exposed image passes through unchanged.
    private func autoExposure(_ planes: inout PixelPlanes, target: Float = 0.5) {
        guard planes.count > 0 else { return }
        let lum = planes.luminance()
        let mean = Vec.mean(lum, stride: analysisStride(planes.count))
        guard mean > 0.02, mean < 0.98 else { return }

        var gamma = Foundation.log(target) / Foundation.log(mean)
        gamma = min(max(gamma, 0.5), 2.0)
        if abs(gamma - 1) < 0.05 { return }

        let newL = Vec.pow(lum, gamma)
        planes.multiply(by: Vec.ratio(newL: newL, overL: lum))
    }

    // MARK: - Stage: Percentile Contrast Stretch

    /// Independent per-channel percentile stretch. Equalizes the R/G/B ranges,
    /// which also neutralizes color casts. Histograms come from a strided
    /// sample; the resulting 256-entry lookup tables are applied to every pixel.
    private func percentileStretchPerChannel(
        _ planes: inout PixelPlanes, lowPct: Float, highPct: Float
    ) {
        guard planes.count > 0 else { return }
        let stride = analysisStride(planes.count)
        func table(_ channel: [Float]) -> [Float] {
            let sample = Vec.sampled(channel, stride: stride)
            let hist = Vec.histogram256(sample, width: sample.count, height: 1)
            return channelMap(histogram: hist, total: sample.count, lowPct: lowPct, highPct: highPct)
        }
        planes.apply(tables: table(planes.r), table(planes.g), table(planes.b))
    }

    /// Single stretch derived from a luminance histogram, applied as an RGB
    /// ratio so color is preserved. Used by the color-preserving intents.
    private func percentileStretchLuminance(
        _ planes: inout PixelPlanes, lowPct: Float, highPct: Float
    ) {
        guard planes.count > 0 else { return }
        let lum = planes.luminance()
        let sample = Vec.sampled(lum, stride: analysisStride(planes.count))
        let hist = Vec.histogram256(sample, width: sample.count, height: 1)

        let low = percentile(histogram: hist, total: sample.count, fraction: lowPct)
        let high = percentile(histogram: hist, total: sample.count, fraction: highPct)
        let range = high - low
        guard range > 0.02 else { return }

        let newL = Vec.clipped(Vec.affine(lum, scale: 1 / range, offset: -low / range))
        planes.multiply(by: Vec.ratio(newL: newL, overL: lum))
    }

    /// Builds a 256-entry lookup table mapping each input level to its
    /// percentile-stretched value for one channel.
    private func channelMap(
        histogram: [Int], total: Int, lowPct: Float, highPct: Float
    ) -> [Float] {
        let low = percentile(histogram: histogram, total: total, fraction: lowPct)
        let high = percentile(histogram: histogram, total: total, fraction: highPct)
        let range = high - low
        guard range > 0.02 else {
            return (0...255).map { Float($0) / 255 }
        }
        let scale = 1.0 / range
        return (0...255).map { value in
            min(1, max(0, (Float(value) / 255.0 - low) * scale))
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

    // MARK: - Stage: CLAHE

    private func applyCLAHE(_ clahe: CLAHEProcessor, to planes: inout PixelPlanes) {
        let lum = planes.luminance()
        let newL = clahe.equalized(lum, width: planes.width, height: planes.height)
        planes.multiply(by: Vec.ratio(newL: newL, overL: lum))
    }

    // MARK: - Stage: Homomorphic Filter

    /// Homomorphic filtering: in the log-luminance domain, attenuate the
    /// low-frequency component (illumination — the source of uneven brightness
    /// and blown-out patches) and amplify the high-frequency component
    /// (reflectance — the actual scene detail). Color is preserved by scaling
    /// RGB by the resulting luminance ratio.
    ///
    /// The illumination field is estimated by block-averaging the
    /// log-luminance into a small grid, smoothing it, and bilinearly
    /// upsampling per row — avoiding a full-resolution Gaussian blur.
    private func homomorphic(
        _ planes: inout PixelPlanes,
        lowGain: Float, highGain: Float, blurFraction: Float
    ) {
        let width = planes.width, height = planes.height
        let count = planes.count
        guard count > 0 else { return }
        let eps: Float = 0.01

        let lum = planes.luminance()
        let logL = Vec.log(Vec.affine(lum, scale: 1, offset: eps))

        // Estimate illumination: block-average log-luminance into a small grid.
        let cell = max(8, Int(Double(min(width, height)) * Double(blurFraction)))
        let fieldW = max(1, (width + cell - 1) / cell)
        let fieldH = max(1, (height + cell - 1) / cell)
        var field = [Float](repeating: 0, count: fieldW * fieldH)
        var counts = [Int](repeating: 0, count: fieldW * fieldH)
        logL.withUnsafeBufferPointer { lg in
            var rowSum = [Float](repeating: 0, count: width)
            var fy = 0
            var rowsInBand = 0
            func flushBand() {
                guard rowsInBand > 0 else { return }
                for fx in 0..<fieldW {
                    let x0 = fx * cell, x1 = min(width, x0 + cell)
                    var sum: Float = 0
                    rowSum.withUnsafeBufferPointer { rs in
                        vDSP_sve(rs.baseAddress! + x0, 1, &sum, vDSP_Length(x1 - x0))
                    }
                    field[fy * fieldW + fx] += sum
                    counts[fy * fieldW + fx] += (x1 - x0) * rowsInBand
                }
                var zero: Float = 0
                vDSP_vfill(&zero, &rowSum, 1, vDSP_Length(width))
                rowsInBand = 0
            }
            for y in 0..<height {
                let bandOfRow = min(fieldH - 1, y / cell)
                if bandOfRow != fy { flushBand(); fy = bandOfRow }
                vDSP_vadd(rowSum, 1, lg.baseAddress! + y * width, 1, &rowSum, 1, vDSP_Length(width))
                rowsInBand += 1
            }
            flushBand()
        }
        for i in 0..<field.count where counts[i] > 0 { field[i] /= Float(counts[i]) }
        field = smoothField(field, width: fieldW, height: fieldH)

        // Bilinearly upsample the field (cell centres) to a full-size plane,
        // one vDSP row at a time using gathers on precomputed column indices.
        let halfCell = Float(cell) / 2
        var gx0 = [vDSP_Length](repeating: 1, count: width)
        var gx1 = [vDSP_Length](repeating: 1, count: width)
        var wx = [Float](repeating: 0, count: width)
        for x in 0..<width {
            let gx = (Float(x) - halfCell + 0.5) / Float(cell)
            let c0 = max(0, min(fieldW - 1, Int(gx.rounded(.down))))
            let c1 = max(0, min(fieldW - 1, c0 + 1))
            gx0[x] = vDSP_Length(c0 + 1)   // vDSP_vgathr indices are 1-based
            gx1[x] = vDSP_Length(c1 + 1)
            wx[x] = max(0, min(1, gx - Float(c0)))
        }
        var low = [Float](repeating: 0, count: count)
        var a0 = [Float](repeating: 0, count: width)
        var a1 = [Float](repeating: 0, count: width)
        var top = [Float](repeating: 0, count: width)
        var bottom = [Float](repeating: 0, count: width)
        let n = vDSP_Length(width)
        field.withUnsafeBufferPointer { fld in
            low.withUnsafeMutableBufferPointer { out in
                for y in 0..<height {
                    let gy = (Float(y) - halfCell + 0.5) / Float(cell)
                    let r0 = max(0, min(fieldH - 1, Int(gy.rounded(.down))))
                    let r1 = max(0, min(fieldH - 1, r0 + 1))
                    var wy = max(0, min(1, gy - Float(r0)))
                    // top = f[r0][gx0] + (f[r0][gx1] - f[r0][gx0]) * wx
                    vDSP_vgathr(fld.baseAddress! + r0 * fieldW, gx0, 1, &a0, 1, n)
                    vDSP_vgathr(fld.baseAddress! + r0 * fieldW, gx1, 1, &a1, 1, n)
                    vDSP_vsub(a0, 1, a1, 1, &a1, 1, n)
                    vDSP_vmul(a1, 1, wx, 1, &a1, 1, n)
                    vDSP_vadd(a0, 1, a1, 1, &top, 1, n)
                    vDSP_vgathr(fld.baseAddress! + r1 * fieldW, gx0, 1, &a0, 1, n)
                    vDSP_vgathr(fld.baseAddress! + r1 * fieldW, gx1, 1, &a1, 1, n)
                    vDSP_vsub(a0, 1, a1, 1, &a1, 1, n)
                    vDSP_vmul(a1, 1, wx, 1, &a1, 1, n)
                    vDSP_vadd(a0, 1, a1, 1, &bottom, 1, n)
                    // low = top + (bottom - top) * wy
                    vDSP_vsub(top, 1, bottom, 1, &bottom, 1, n)
                    vDSP_vsmul(bottom, 1, &wy, &bottom, 1, n)
                    vDSP_vadd(top, 1, bottom, 1, out.baseAddress! + y * width, 1, n)
                }
            }
        }

        // newLog = lowGain * low + highGain * (logL - low); newL = exp(newLog) - eps
        var newLog = [Float](repeating: 0, count: count)
        let cn = vDSP_Length(count)
        vDSP_vsub(low, 1, logL, 1, &newLog, 1, cn)          // logL - low
        var hg = highGain, lg = lowGain
        vDSP_vsmul(newLog, 1, &hg, &newLog, 1, cn)
        vDSP_vsma(low, 1, &lg, newLog, 1, &newLog, 1, cn)   // + lowGain * low
        let newL = Vec.clipped(Vec.affine(Vec.exp(newLog), scale: 1, offset: -eps), low: 0, high: .greatestFiniteMagnitude)
        planes.multiply(by: Vec.ratio(newL: newL, overL: lum))
    }

    /// A single separable 1-2-1 pass to take the blockiness off the downsampled
    /// illumination field.
    private func smoothField(_ field: [Float], width: Int, height: Int) -> [Float] {
        guard width > 2, height > 2 else { return field }
        var temp = field
        for y in 0..<height {
            let base = y * width
            for x in 0..<width {
                let x0 = max(0, x - 1)
                let x1 = min(width - 1, x + 1)
                temp[base + x] = (field[base + x0] + 2 * field[base + x] + field[base + x1]) / 4
            }
        }
        var result = field
        for y in 0..<height {
            let y0 = max(0, y - 1) * width
            let y1 = min(height - 1, y + 1) * width
            let base = y * width
            for x in 0..<width {
                result[base + x] = (temp[y0 + x] + 2 * temp[base + x] + temp[y1 + x]) / 4
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
    /// sample of a luminance plane.
    private func luminanceStats(_ lum: [Float]) -> (mean: Float, std: Float) {
        guard !lum.isEmpty else { return (0, 0) }
        let stride = analysisStride(lum.count)
        let mean = Vec.mean(lum, stride: stride)
        let meanSq = Vec.meanOfSquares(lum, stride: stride)
        return (mean, max(0, meanSq - mean * mean).squareRoot())
    }

    /// Remaps one image's luminance via `(l - sourceMean) * gain + targetMean`,
    /// preserving color by scaling RGB by the luminance ratio.
    private func applyLuminanceAffine(
        _ cgImage: CGImage, planes: PixelPlanes, luminance: [Float],
        sourceMean: Float, sourceStd: Float,
        targetMean: Float, targetStd: Float
    ) -> CGImage? {
        guard planes.count > 0 else { return cgImage }
        let gain = sourceStd > 0.001 ? targetStd / sourceStd : 1.0
        let newL = Vec.clipped(Vec.affine(luminance, scale: gain, offset: targetMean - sourceMean * gain))
        var out = planes
        out.multiply(by: Vec.ratio(newL: newL, overL: luminance))
        return makeRGBA(out.rgba(), width: planes.width, height: planes.height, colorSpace: cgImage.colorSpace)
    }

    // MARK: - Pixel Helpers

    /// Number of pixels to skip between samples when only image statistics are
    /// needed. Caps analysis passes at ~300k samples regardless of resolution.
    private func analysisStride(_ count: Int) -> Int {
        max(1, count / 300_000)
    }

    private func readPlanes(_ cgImage: CGImage) -> PixelPlanes? {
        guard let rgba = readRGBA(cgImage) else { return nil }
        return PixelPlanes(rgba: rgba, width: cgImage.width, height: cgImage.height)
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
}
