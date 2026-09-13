import Vision
import CoreVideo
import CoreGraphics
import OSLog
import simd

/// Stereo-aware restoration that exploits the second eye as ground truth.
///
/// A stereo pair gives us two views of the same scene, so a defect or a blown
/// highlight that ruins one eye at a scene point almost always leaves the *other*
/// eye intact there (just shifted by parallax). This processor detects those
/// problems and repairs them by borrowing the disparity-corresponding pixels
/// from the sibling eye, found via dense optical flow.
///
/// Both repairs — dust/scratch removal and blown-highlight recovery — need the
/// same expensive ingredient: bidirectional optical flow between the eyes. This
/// type computes that **once** (and calibrates its sign once per direction) and
/// drives both stages from it, rather than paying for flow twice.
///
/// Holds no mutable state; runs only on the deliberate "deep" path. Optical flow
/// is resource-intensive, so the two flows are computed one at a time, and the
/// whole thing short-circuits before any flow when the pair is clean.
nonisolated final class StereoPairProcessor: @unchecked Sendable {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "StereoProcessor"
    )

    // MARK: - Defect Tunables

    /// Structuring-element radius for defect detection. Blemishes up to roughly
    /// `2 * seRadius + 1` px across are caught.
    private let seRadius = 2
    /// Minimum local top-hat/bottom-hat contrast (0...1) for a defect pixel.
    private let defectThreshold: Float = 0.11
    /// The detected defect mask is grown by this radius to cover soft edges.
    private let maskDilation = 1
    /// Forward-backward flow agreement (px) required to trust a defect fill.
    private let fbDefectPx: Float = 2.5
    /// Above this flagged fraction the "defects" are really texture — skip.
    private let maxDefectFraction: Float = 0.12

    // MARK: - Highlight Tunables

    /// Luminance (0...1) at or above which a pixel is treated as clipped.
    private let clipThreshold: Float = 0.96
    /// Skip highlight recovery for an eye clipped less than this.
    private let minClipFraction: Float = 0.004
    /// …or more than this (a legitimately bright card, not a defect).
    private let maxClipFraction: Float = 0.5
    /// Forward-backward flow agreement (px) required to trust a highlight fill.
    private let fbHighlightPx: Float = 3.0
    /// Feather radius (px) for blending recovered highlights into the clipped edge.
    private let featherRadius = 3
    /// Bounds on the sibling→damaged exposure rescale.
    private let minGain: Float = 0.5
    private let maxGain: Float = 2.5

    // MARK: - Public API

    /// Removes dust/scratches and recovers blown highlights across the pair,
    /// sharing one bidirectional optical-flow computation. Returns the input
    /// unchanged when nothing needs repair or a prerequisite is missing.
    func process(
        left: CGImage, right: CGImage
    ) -> (left: CGImage, right: CGImage) {
        guard left.width == right.width, left.height == right.height,
              var leftPixels = readRGBA(left),
              var rightPixels = readRGBA(right) else {
            return (left, right)
        }
        let width = left.width
        let height = left.height
        let count = width * height

        let leftLum = luminance(leftPixels, count: count)
        let rightLum = luminance(rightPixels, count: count)

        // Detect both problem types up front (all cheap, CPU).
        var leftDefects = defectMask(leftLum, width: width, height: height)
        var rightDefects = defectMask(rightLum, width: width, height: height)
        let maxFlagged = Int(Float(count) * maxDefectFraction)
        if leftDefects.lazy.filter({ $0 }).count > maxFlagged { leftDefects = Array(repeating: false, count: count) }
        if rightDefects.lazy.filter({ $0 }).count > maxFlagged { rightDefects = Array(repeating: false, count: count) }
        let leftDefectCount = leftDefects.lazy.filter { $0 }.count
        let rightDefectCount = rightDefects.lazy.filter { $0 }.count

        let leftClip = clipMask(leftLum)
        let rightClip = clipMask(rightLum)
        let leftClipFrac = fraction(leftClip)
        let rightClipFrac = fraction(rightClip)
        let leftRecoverable = leftClipFrac >= minClipFraction && leftClipFrac <= maxClipFraction
        let rightRecoverable = rightClipFrac >= minClipFraction && rightClipFrac <= maxClipFraction

        let needDefects = leftDefectCount > 0 || rightDefectCount > 0
        let needHighlights = leftRecoverable || rightRecoverable
        guard needDefects || needHighlights else {
            return (left, right)   // clean pair — never touch optical flow
        }
        logger.info("Stereo repair — defects L/R: \(leftDefectCount, privacy: .public)/\(rightDefectCount, privacy: .public), clip L/R: \(leftClipFrac, privacy: .public)/\(rightClipFrac, privacy: .public)")

        // The one expensive step, shared by both stages (one request at a time).
        guard let flowLtoR = opticalFlow(reference: left, target: right, width: width, height: height),
              let flowRtoL = opticalFlow(reference: right, target: left, width: width, height: height) else {
            // No flow: still salvage defects with single-image inpaint.
            logger.warning("Optical flow unavailable; single-image defect inpaint only")
            if leftDefectCount > 0 { inpaintSingle(&leftPixels, mask: leftDefects, width: width, height: height) }
            if rightDefectCount > 0 { inpaintSingle(&rightPixels, mask: rightDefects, width: width, height: height) }
            let l = makeRGBA(leftPixels, width: width, height: height, colorSpace: left.colorSpace) ?? left
            let r = makeRGBA(rightPixels, width: width, height: height, colorSpace: right.colorSpace) ?? right
            return (l, r)
        }

        // Sign is a property of the flow itself, so calibrate once per direction
        // and reuse for every stage.
        let signLtoR = calibrateSign(flow: flowLtoR, refLum: leftLum, targetLum: rightLum, width: width, height: height)
        let signRtoL = calibrateSign(flow: flowRtoL, refLum: rightLum, targetLum: leftLum, width: width, height: height)

        // --- Stage 1: defect removal (fill from the sibling's untouched pixels) ---
        if needDefects {
            let leftOriginal = leftPixels
            let rightOriginal = rightPixels
            if leftDefectCount > 0 {
                inpaintFromSibling(
                    &leftPixels, mask: leftDefects,
                    sibling: rightOriginal, siblingMask: rightDefects,
                    flow: flowLtoR, sign: signLtoR, backFlow: flowRtoL, backSign: signRtoL,
                    width: width, height: height
                )
            }
            if rightDefectCount > 0 {
                inpaintFromSibling(
                    &rightPixels, mask: rightDefects,
                    sibling: leftOriginal, siblingMask: leftDefects,
                    flow: flowRtoL, sign: signRtoL, backFlow: flowLtoR, backSign: signLtoR,
                    width: width, height: height
                )
            }
        }

        // --- Stage 2: highlight recovery (sample the now defect-cleaned sibling) ---
        if needHighlights {
            let leftClean = leftPixels
            let rightClean = rightPixels
            if leftRecoverable {
                recoverHighlights(
                    &leftPixels, clipMask: leftClip, selfLum: leftLum,
                    sibling: rightClean, siblingLum: rightLum, siblingClip: rightClip,
                    flow: flowLtoR, sign: signLtoR, backFlow: flowRtoL, backSign: signRtoL,
                    width: width, height: height
                )
            }
            if rightRecoverable {
                recoverHighlights(
                    &rightPixels, clipMask: rightClip, selfLum: rightLum,
                    sibling: leftClean, siblingLum: leftLum, siblingClip: leftClip,
                    flow: flowRtoL, sign: signRtoL, backFlow: flowLtoR, backSign: signLtoR,
                    width: width, height: height
                )
            }
        }

        let outLeft = makeRGBA(leftPixels, width: width, height: height, colorSpace: left.colorSpace) ?? left
        let outRight = makeRGBA(rightPixels, width: width, height: height, colorSpace: right.colorSpace) ?? right
        return (outLeft, outRight)
    }

    // MARK: - Debug Visualization

    /// Each eye with its detected defect mask painted red over a dimmed original,
    /// for tuning the detector. Identical detection to `process` (including the
    /// runaway-mask guard); the sibling-fill stage is not exercised.
    func debugMaskOverlay(
        left: CGImage, right: CGImage
    ) -> (left: CGImage, right: CGImage) {
        (maskOverlay(left), maskOverlay(right))
    }

    private func maskOverlay(_ image: CGImage) -> CGImage {
        guard var pixels = readRGBA(image) else { return image }
        let width = image.width, height = image.height, count = width * height
        let lum = luminance(pixels, count: count)
        var mask = defectMask(lum, width: width, height: height)
        if mask.lazy.filter({ $0 }).count > Int(Float(count) * maxDefectFraction) {
            mask = Array(repeating: false, count: count)
        }
        for i in 0..<count {
            let base = i * 4
            if mask[i] {
                pixels[base] = 255; pixels[base + 1] = 0; pixels[base + 2] = 0
            } else {
                pixels[base] = UInt8(Int(pixels[base]) * 2 / 5)
                pixels[base + 1] = UInt8(Int(pixels[base + 1]) * 2 / 5)
                pixels[base + 2] = UInt8(Int(pixels[base + 2]) * 2 / 5)
            }
        }
        return makeRGBA(pixels, width: width, height: height, colorSpace: image.colorSpace) ?? image
    }

    // MARK: - Optical Flow

    /// Dense per-pixel displacement mapping each `reference` pixel to `target`,
    /// in reference-pixel units. `nil` on failure.
    private func opticalFlow(
        reference: CGImage, target: CGImage, width: Int, height: Int
    ) -> [SIMD2<Float>]? {
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: target)
        request.computationAccuracy = .high
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        let handler = VNImageRequestHandler(cgImage: reference)
        do {
            try handler.perform([request])
        } catch {
            logger.error("Optical flow failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let flowW = CVPixelBufferGetWidth(buffer)
        let flowH = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        var flow = [SIMD2<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            let sy = min(flowH - 1, y * flowH / height)
            let row = base.advanced(by: sy * rowBytes).assumingMemoryBound(to: Float.self)
            let outRow = y * width
            for x in 0..<width {
                let sx = min(flowW - 1, x * flowW / width)
                flow[outRow + x] = SIMD2(row[sx * 2], row[sx * 2 + 1])
            }
        }
        return flow
    }

    /// Picks the flow sign (+1/−1) whose warp best aligns `refLum` onto
    /// `targetLum` over a strided sample, making the pipeline robust to Vision's
    /// undocumented flow-direction convention.
    private func calibrateSign(
        flow: [SIMD2<Float>], refLum: [Float], targetLum: [Float], width: Int, height: Int
    ) -> Float {
        let total = width * height
        let step = max(1, total / 4000)
        var residualPos: Float = 0
        var residualNeg: Float = 0
        var samples = 0
        var i = 0
        while i < total {
            let f = flow[i]
            if abs(f.x) > 0.5 || abs(f.y) > 0.5 {
                let x = Float(i % width)
                let y = Float(i / width)
                let base = refLum[i]
                residualPos += abs(base - sampleLuminance(targetLum, x: x + f.x, y: y + f.y, width: width, height: height))
                residualNeg += abs(base - sampleLuminance(targetLum, x: x - f.x, y: y - f.y, width: width, height: height))
                samples += 1
            }
            i += step
        }
        guard samples > 20 else { return 1 }
        return residualPos <= residualNeg ? 1 : -1
    }

    // MARK: - Defect Detection

    private func defectMask(_ lum: [Float], width: Int, height: Int) -> [Bool] {
        let opening = morphMax(morphMin(lum, width, height, seRadius), width, height, seRadius)
        let closing = morphMin(morphMax(lum, width, height, seRadius), width, height, seRadius)
        var mask = [Bool](repeating: false, count: width * height)
        for i in 0..<(width * height) {
            let topHat = lum[i] - opening[i]
            let botHat = closing[i] - lum[i]
            if max(topHat, botHat) > defectThreshold { mask[i] = true }
        }
        return maskDilation > 0 ? dilateMask(mask, width: width, height: height, radius: maskDilation) : mask
    }

    // MARK: - Sibling Inpainting (Defects)

    private func inpaintFromSibling(
        _ pixels: inout [UInt8], mask: [Bool],
        sibling: [UInt8], siblingMask: [Bool],
        flow: [SIMD2<Float>], sign: Float, backFlow: [SIMD2<Float>], backSign: Float,
        width: Int, height: Int
    ) {
        var unresolved = [Bool](repeating: false, count: width * height)
        for idx in 0..<(width * height) where mask[idx] {
            let x = Float(idx % width)
            let y = Float(idx / width)
            let f = flow[idx]
            let qx = x + sign * f.x
            let qy = y + sign * f.y
            guard inBounds(qx, qy, width, height) else { unresolved[idx] = true; continue }

            let qIdx = Int(qy.rounded()) * width + Int(qx.rounded())
            if siblingMask[qIdx] { unresolved[idx] = true; continue }

            let bf = backFlow[qIdx]
            if hypotf(qx + backSign * bf.x - x, qy + backSign * bf.y - y) > fbDefectPx {
                unresolved[idx] = true; continue
            }

            let rgb = sampleRGB(sibling, x: qx, y: qy, width: width, height: height)
            let base = idx * 4
            pixels[base] = rgb.0; pixels[base + 1] = rgb.1; pixels[base + 2] = rgb.2
        }
        inpaintSingle(&pixels, mask: unresolved, width: width, height: height)
    }

    /// Fills masked pixels by repeatedly averaging each hole pixel's already-good
    /// 8-neighbors, growing inward from the boundary.
    private func inpaintSingle(
        _ pixels: inout [UInt8], mask: [Bool], width: Int, height: Int
    ) {
        var remaining = mask
        var todo = (0..<(width * height)).filter { mask[$0] }
        guard !todo.isEmpty else { return }

        var iterations = 0
        while !todo.isEmpty && iterations < 128 {
            var filled: [(index: Int, r: Int, g: Int, b: Int)] = []
            var stillTodo: [Int] = []
            for idx in todo {
                let x = idx % width, y = idx / width
                var sr = 0, sg = 0, sb = 0, n = 0
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0) {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        let nIdx = ny * width + nx
                        if !remaining[nIdx] {
                            let b = nIdx * 4
                            sr += Int(pixels[b]); sg += Int(pixels[b + 1]); sb += Int(pixels[b + 2]); n += 1
                        }
                    }
                }
                if n > 0 { filled.append((idx, sr / n, sg / n, sb / n)) } else { stillTodo.append(idx) }
            }
            if filled.isEmpty { break }
            for f in filled {
                let b = f.index * 4
                pixels[b] = UInt8(f.r); pixels[b + 1] = UInt8(f.g); pixels[b + 2] = UInt8(f.b)
                remaining[f.index] = false
            }
            todo = stillTodo
            iterations += 1
        }
    }

    // MARK: - Highlight Recovery

    private func clipMask(_ lum: [Float]) -> [Bool] {
        lum.map { $0 >= clipThreshold }
    }

    private func recoverHighlights(
        _ pixels: inout [UInt8], clipMask: [Bool], selfLum: [Float],
        sibling: [UInt8], siblingLum: [Float], siblingClip: [Bool],
        flow: [SIMD2<Float>], sign: Float, backFlow: [SIMD2<Float>], backSign: Float,
        width: Int, height: Int
    ) {
        let gain = exposureGain(
            selfLum: selfLum, siblingLum: siblingLum, flow: flow, sign: sign,
            skip: clipMask, siblingSkip: siblingClip, width: width, height: height
        )

        let count = width * height
        var recovered = pixels
        var valid = [Bool](repeating: false, count: count)

        for idx in 0..<count where clipMask[idx] {
            let x = Float(idx % width)
            let y = Float(idx / width)
            let f = flow[idx]
            let qx = x + sign * f.x
            let qy = y + sign * f.y
            guard inBounds(qx, qy, width, height) else { continue }

            let qIdx = Int(qy.rounded()) * width + Int(qx.rounded())
            if siblingClip[qIdx] { continue }

            let bf = backFlow[qIdx]
            if hypotf(qx + backSign * bf.x - x, qy + backSign * bf.y - y) > fbHighlightPx { continue }

            let rgb = sampleRGB(sibling, x: qx, y: qy, width: width, height: height)
            let base = idx * 4
            recovered[base] = scale(rgb.0, gain)
            recovered[base + 1] = scale(rgb.1, gain)
            recovered[base + 2] = scale(rgb.2, gain)
            valid[idx] = true
        }

        let alpha = boxBlur(valid.map { $0 ? Float(1) : 0 }, width: width, height: height, radius: featherRadius)
        for idx in 0..<count where valid[idx] {
            let a = alpha[idx]
            let base = idx * 4
            pixels[base] = blend(pixels[base], recovered[base], a)
            pixels[base + 1] = blend(pixels[base + 1], recovered[base + 1], a)
            pixels[base + 2] = blend(pixels[base + 2], recovered[base + 2], a)
        }
    }

    /// Single exposure ratio (damaged / sibling) over a strided sample of
    /// non-clipped correspondences, clamped.
    private func exposureGain(
        selfLum: [Float], siblingLum: [Float], flow: [SIMD2<Float>], sign: Float,
        skip: [Bool], siblingSkip: [Bool], width: Int, height: Int
    ) -> Float {
        let total = width * height
        let step = max(1, total / 4000)
        var sumSelf: Float = 0
        var sumSibling: Float = 0
        var i = 0
        while i < total {
            let f = flow[i]
            if !skip[i] && (abs(f.x) > 0.5 || abs(f.y) > 0.5) {
                let x = Float(i % width) + sign * f.x
                let y = Float(i / width) + sign * f.y
                if inBounds(x, y, width, height) {
                    let qIdx = Int(y.rounded()) * width + Int(x.rounded())
                    if !siblingSkip[qIdx] {
                        sumSelf += selfLum[i]
                        sumSibling += sampleLuminance(siblingLum, x: x, y: y, width: width, height: height)
                    }
                }
            }
            i += step
        }
        guard sumSibling > 0.001 else { return 1 }
        return min(maxGain, max(minGain, sumSelf / sumSibling))
    }

    // MARK: - Morphology

    private func morphMin(_ s: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        morph(s, w, h, r, keepLarger: false)
    }

    private func morphMax(_ s: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        morph(s, w, h, r, keepLarger: true)
    }

    private func morph(_ s: [Float], _ w: Int, _ h: Int, _ r: Int, keepLarger: Bool) -> [Float] {
        func better(_ a: Float, _ b: Float) -> Float { keepLarger ? max(a, b) : min(a, b) }
        var temp = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let rowBase = y * w
            for x in 0..<w {
                var acc = s[rowBase + x]
                let x0 = max(0, x - r), x1 = min(w - 1, x + r)
                for xx in x0...x1 { acc = better(acc, s[rowBase + xx]) }
                temp[rowBase + x] = acc
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for x in 0..<w {
            for y in 0..<h {
                var acc = temp[y * w + x]
                let y0 = max(0, y - r), y1 = min(h - 1, y + r)
                for yy in y0...y1 { acc = better(acc, temp[yy * w + x]) }
                out[y * w + x] = acc
            }
        }
        return out
    }

    private func dilateMask(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
                for yy in y0...y1 { for xx in x0...x1 { out[yy * width + xx] = true } }
            }
        }
        return out
    }

    private func boxBlur(_ field: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return field }
        let window = Float(2 * radius + 1)
        var temp = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                var acc: Float = 0
                let x0 = max(0, x - radius), x1 = min(width - 1, x + radius)
                for xx in x0...x1 { acc += field[rowBase + xx] }
                temp[rowBase + x] = acc / window
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for x in 0..<width {
            for y in 0..<height {
                var acc: Float = 0
                let y0 = max(0, y - radius), y1 = min(height - 1, y + radius)
                for yy in y0...y1 { acc += temp[yy * width + x] }
                out[y * width + x] = acc / window
            }
        }
        return out
    }

    // MARK: - Sampling / Pixel Helpers

    private func scale(_ value: UInt8, _ gain: Float) -> UInt8 {
        UInt8(max(0, min(255, (Float(value) * gain).rounded())))
    }

    private func blend(_ original: UInt8, _ replacement: UInt8, _ alpha: Float) -> UInt8 {
        UInt8(max(0, min(255, (Float(original) * (1 - alpha) + Float(replacement) * alpha).rounded())))
    }

    private func inBounds(_ x: Float, _ y: Float, _ w: Int, _ h: Int) -> Bool {
        x >= 0 && y >= 0 && x <= Float(w - 1) && y <= Float(h - 1)
    }

    private func sampleLuminance(_ lum: [Float], x: Float, y: Float, width: Int, height: Int) -> Float {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let cx0 = min(width - 1, max(0, x0)), cy0 = min(height - 1, max(0, y0))
        let cx1 = min(width - 1, max(0, x0 + 1)), cy1 = min(height - 1, max(0, y0 + 1))
        let top = lum[cy0 * width + cx0] * (1 - fx) + lum[cy0 * width + cx1] * fx
        let bot = lum[cy1 * width + cx0] * (1 - fx) + lum[cy1 * width + cx1] * fx
        return top * (1 - fy) + bot * fy
    }

    private func sampleRGB(_ px: [UInt8], x: Float, y: Float, width: Int, height: Int) -> (UInt8, UInt8, UInt8) {
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = x - Float(x0), fy = y - Float(y0)
        let cx0 = min(width - 1, max(0, x0)), cy0 = min(height - 1, max(0, y0))
        let cx1 = min(width - 1, max(0, x0 + 1)), cy1 = min(height - 1, max(0, y0 + 1))
        func channel(_ c: Int) -> UInt8 {
            func at(_ xx: Int, _ yy: Int) -> Float { Float(px[(yy * width + xx) * 4 + c]) }
            let top = at(cx0, cy0) * (1 - fx) + at(cx1, cy0) * fx
            let bot = at(cx0, cy1) * (1 - fx) + at(cx1, cy1) * fx
            return UInt8(max(0, min(255, (top * (1 - fy) + bot * fy).rounded())))
        }
        return (channel(0), channel(1), channel(2))
    }

    private func fraction(_ mask: [Bool]) -> Float {
        guard !mask.isEmpty else { return 0 }
        return Float(mask.lazy.filter { $0 }.count) / Float(mask.count)
    }

    private func luminance(_ px: [UInt8], count: Int) -> [Float] {
        var lum = [Float](repeating: 0, count: count)
        px.withUnsafeBufferPointer { src in
            lum.withUnsafeMutableBufferPointer { out in
                for i in 0..<count {
                    let b = i * 4
                    out[i] = 0.2126 * Float(src[b]) / 255
                        + 0.7152 * Float(src[b + 1]) / 255
                        + 0.0722 * Float(src[b + 2]) / 255
                }
            }
        }
        return lum
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
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
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
