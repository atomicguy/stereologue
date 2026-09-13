//
//  StereoResidual.swift
//  Stereologue
//
//  Rectified block-matching disparity plus the "stereo residual": what is
//  left after the other eye is warped into this eye's frame and exposure
//  normalized. Dust, scratches, writing, and captions that exist in only one
//  eye light up in the residual regardless of what they look like, because
//  they have no counterpart at the corresponding scene point.
//
//  Experiment tooling for PLAN-fall-2026.md Phase 3.3b. Everything runs on
//  downscaled luminance planes with vDSP/vImage, off the main actor.
//

import Accelerate
import CoreGraphics
import Foundation
import Vision

nonisolated struct StereoResidual: Sendable {

    /// Analysis-scale results for both eyes. Planes are `width`×`height`;
    /// `scale` maps analysis pixels back to the full-size eyes.
    struct Result: Sendable {
        let width: Int
        let height: Int
        let fullWidth: Int
        let fullHeight: Int
        var scale: Double { Double(width) / Double(fullWidth) }
        /// Horizontal offset (analysis px) at which the right eye best matches
        /// the left overall; the block search is centred on it.
        let globalShift: Int
        /// Per-pixel disparity d such that left[x] ≈ right[x + d]. Where the
        /// match failed the left-right check the value is filled in from the
        /// smooth field of the valid neighbours, so a one-eye defect (which
        /// has no match by definition) is still warped and compared.
        let disparityLeft: [Float]
        /// 1 where the left→right match passed the left-right check.
        let validLeft: [Float]
        /// |left − warp(right)| after local exposure normalization.
        let residualLeft: [Float]
        let disparityRight: [Float]
        let validRight: [Float]
        let residualRight: [Float]

        var validFractionLeft: Double { Double(Vec.mean(validLeft)) }
        var validFractionRight: Double { Double(Vec.mean(validRight)) }
        func flaggedFraction(left: Bool, threshold: Float) -> Double {
            Double(Vec.fraction(of: left ? residualLeft : residualRight, atLeast: threshold))
        }
    }

    /// Both eyes are downscaled (same factor) so the wider is at most this.
    var analysisMaxWidth = 512
    /// Matching window is (2r+1)² pixels.
    var blockRadius = 6
    /// Disparities searched either side of the global shift.
    var searchRadius = 32
    /// Left-right agreement (px) required to trust a match.
    var lrTolerance: Float = 2
    /// Radius of the local-mean window used to normalize exposure before
    /// differencing, so vignetting and one-sided fading don't read as defects.
    var normalizationRadius = 15
    /// The residual at a pixel is the smallest difference within ±this many
    /// pixels of the warped position, so sub-pixel disparity and residual
    /// rectification error don't register as defects.
    var toleranceRadius = 1
    /// Both eyes are box-blurred by this radius before differencing to
    /// suppress grain and JPEG noise.
    var smoothingRadius = 1
    /// Local contrast is added to this floor when normalizing the residual,
    /// so a mismatch inside busy texture counts for less than one on a
    /// flat area. Residual units are "difference ÷ (local contrast + floor)".
    var contrastFloor: Float = 0.08
    /// Fraction of width/height at each edge ignored (print borders, mount).
    var borderFraction: Double = 0.03
    /// Residual is scaled down near disparity discontinuities, where stereo
    /// occlusions (background visible in one eye only) produce genuine
    /// differences that are not defects. A disparity gradient of this many
    /// px per px fully suppresses the residual.
    var occlusionGradient: Float = 4
    /// Where fewer than this fraction of the pixels in a wide neighbourhood
    /// (about an eighth of the image) matched, the area is reported as unknown
    /// (residual 0, tinted in the overlay) rather than judged: the fill-in
    /// disparity is a guess there. The window is deliberately wide so a
    /// large one-eye defect such as a caption, which has no matches inside
    /// it, is still judged from the matches around it.
    var unknownCoverage: Float = 0.15

    static func unknownRadius(width: Int, height: Int) -> Int { max(8, min(width, height) / 8) }

    // MARK: - Analysis

    func analyze(left: CGImage, right: CGImage) -> Result? {
        let widest = Double(max(left.width, right.width))
        let factor = min(1.0, Double(analysisMaxWidth) / widest)
        guard let leftSmall = factor < 1 ? Vec.downscaled(left, by: factor) : left,
              let rightSmall = factor < 1 ? Vec.downscaled(right, by: factor) : right,
              let leftPlanes = Vec.planes(of: leftSmall),
              let rightPlanes = Vec.planes(of: rightSmall) else { return nil }
        // Work on the common size (the renderer already dimension-matches).
        let width = min(leftPlanes.width, rightPlanes.width)
        let height = min(leftPlanes.height, rightPlanes.height)
        guard width > 2 * searchRadius + 8, height > 2 * blockRadius + 2 else { return nil }
        let l = Self.cropped(leftPlanes.luminance(), from: leftPlanes.width, to: width, height: height)
        let r = Self.cropped(rightPlanes.luminance(), from: rightPlanes.width, to: width, height: height)

        let shift = globalShift(l, r, leftImage: leftSmall, rightImage: rightSmall, width: width, height: height)
        let dL = blockMatch(reference: l, target: r, width: width, height: height, center: shift)
        let dR = blockMatch(reference: r, target: l, width: width, height: height, center: -shift)
        let vL = consistency(dL, other: dR, width: width, height: height)
        let vR = consistency(dR, other: dL, width: width, height: height)
        let fL = filled(dL, valid: vL, fallback: Float(shift), width: width, height: height)
        let fR = filled(dR, valid: vR, fallback: Float(-shift), width: width, height: height)
        var resL = residual(reference: l, other: r, disparity: fL, width: width, height: height)
        var resR = residual(reference: r, other: l, disparity: fR, width: width, height: height)
        suppressOcclusionsAndUnknowns(&resL, disparity: fL, valid: vL, width: width, height: height)
        suppressOcclusionsAndUnknowns(&resR, disparity: fR, valid: vR, width: width, height: height)

        return Result(
            width: width, height: height,
            fullWidth: left.width, fullHeight: left.height,
            globalShift: shift,
            disparityLeft: fL, validLeft: vL, residualLeft: resL,
            disparityRight: fR, validRight: vR, residualRight: resR
        )
    }

    /// Whole-image horizontal alignment, seeding the block search. Vision's
    /// translational registration is robust on low-texture prints; its sign
    /// convention is checked by evaluating both signs, and a coarse SAD sweep
    /// is the fallback when registration fails.
    private func globalShift(_ l: [Float], _ r: [Float], leftImage: CGImage, rightImage: CGImage, width: Int, height: Int) -> Int {
        // Candidates: Vision's registration in both sign conventions, plus the
        // coarse SAD sweep. Whichever aligns the whole image best wins, so a
        // bogus registration (e.g. on texture-free or synthetic input) loses.
        var candidates = [sadSweep(l, r, width: width, height: height)]
        if let tx = registrationShift(reference: leftImage, floating: rightImage), tx.isFinite {
            candidates += [Int(tx.rounded()), -Int(tx.rounded())]
        }
        let costs = candidates.map { sadCost(l, r, shift: $0, width: width, height: height) }
        return zip(candidates, costs).min(by: { $0.1 < $1.1 })?.0 ?? 0
    }

    private func registrationShift(reference: CGImage, floating: CGImage) -> Float? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: floating)
        let handler = VNImageRequestHandler(cgImage: reference)
        guard (try? handler.perform([request])) != nil,
              let result = request.results?.first else { return nil }
        return Float(result.alignmentTransform.tx)
    }

    /// Mean absolute difference between l[x] and r[x + shift] over the overlap.
    private func sadCost(_ l: [Float], _ r: [Float], shift s: Int, width: Int, height: Int) -> Float {
        let x0 = max(0, -s), x1 = min(width, width - s)
        let n = x1 - x0
        guard n > width / 2 else { return .infinity }
        var total: Float = 0
        var diff = [Float](repeating: 0, count: n)
        for y in 0..<height {
            l.withUnsafeBufferPointer { lp in
                r.withUnsafeBufferPointer { rp in
                    vDSP_vsub(rp.baseAddress! + y * width + x0 + s, 1, lp.baseAddress! + y * width + x0, 1, &diff, 1, vDSP_Length(n))
                }
            }
            vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(n))
            var sum: Float = 0
            vDSP_sve(diff, 1, &sum, vDSP_Length(n))
            total += sum / Float(n)
        }
        return total / Float(height)
    }

    private func sadSweep(_ l: [Float], _ r: [Float], width: Int, height: Int) -> Int {
        let maxShift = width / 4
        var best = 0
        var bestCost = Float.greatestFiniteMagnitude
        let stride = max(1, height / 64)   // sample rows; this only seeds the search
        for s in -maxShift...maxShift {
            let x0 = max(0, -s), x1 = min(width, width - s)
            let n = x1 - x0
            guard n > width / 2 else { continue }
            var total: Float = 0
            var rows = 0
            var y = 0
            var diff = [Float](repeating: 0, count: n)
            while y < height {
                l.withUnsafeBufferPointer { lp in
                    r.withUnsafeBufferPointer { rp in
                        vDSP_vsub(rp.baseAddress! + y * width + x0 + s, 1, lp.baseAddress! + y * width + x0, 1, &diff, 1, vDSP_Length(n))
                    }
                }
                vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(n))
                var sum: Float = 0
                vDSP_sve(diff, 1, &sum, vDSP_Length(n))
                total += sum / Float(n)
                rows += 1
                y += stride
            }
            let cost = total / Float(max(1, rows))
            if cost < bestCost { bestCost = cost; best = s }
        }
        return best
    }

    /// Winner-takes-all block matching: for each reference pixel, the
    /// disparity d in [center − r, center + r] minimizing the box-filtered
    /// absolute difference between reference[x] and target[x + d].
    private func blockMatch(reference: [Float], target: [Float], width: Int, height: Int, center: Int) -> [Float] {
        let n = width * height
        let count = vDSP_Length(n)
        var bestCost = [Float](repeating: .greatestFiniteMagnitude, count: n)
        var bestD = [Float](repeating: Float(center), count: n)
        var shifted = [Float](repeating: 1, count: n)
        var diff = [Float](repeating: 0, count: n)
        var cost = [Float](repeating: 0, count: n)
        var improved = [Float](repeating: 0, count: n)
        var one: Float = 1, zero: Float = 0, half: Float = 0.5

        for d in (center - searchRadius)...(center + searchRadius) {
            // shifted[x] = target[x + d]; out of range costs the maximum.
            var fill: Float = 1
            vDSP_vfill(&fill, &shifted, 1, count)
            let x0 = max(0, -d), x1 = min(width, width - d)
            if x1 > x0 {
                target.withUnsafeBufferPointer { tp in
                    shifted.withUnsafeMutableBufferPointer { sp in
                        for y in 0..<height {
                            sp.baseAddress!.advanced(by: y * width + x0)
                                .update(from: tp.baseAddress!.advanced(by: y * width + x0 + d), count: x1 - x0)
                        }
                    }
                }
            }
            vDSP_vsub(shifted, 1, reference, 1, &diff, 1, count)
            vDSP_vabs(diff, 1, &diff, 1, count)
            Vec.boxBlur(diff, into: &cost, width: width, height: height, radius: blockRadius)

            // improved = 1 where cost < bestCost, else 0
            vDSP_vsub(cost, 1, bestCost, 1, &improved, 1, count)      // bestCost - cost
            vDSP_vthrsc(improved, 1, &zero, &half, &improved, 1, count) // ±0.5
            vDSP_vsadd(improved, 1, &half, &improved, 1, count)        // 0 / 1
            vDSP_vmin(cost, 1, bestCost, 1, &bestCost, 1, count)
            // bestD += (d - bestD) * improved
            var dv = Float(d)
            vDSP_vsub(bestD, 1, [Float](repeating: dv, count: 1), 0, &diff, 1, count) // diff = d - bestD  (stride-0 scalar)
            vDSP_vmul(diff, 1, improved, 1, &diff, 1, count)
            vDSP_vadd(bestD, 1, diff, 1, &bestD, 1, count)
            _ = one; _ = dv
        }
        return bestD
    }

    /// 1 where the match in one direction lands on a pixel whose reverse match
    /// points back within `lrTolerance`, and stays inside the image.
    private func consistency(_ d: [Float], other: [Float], width: Int, height: Int) -> [Float] {
        var valid = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let dx = d[row + x]
                let xr = Int((Float(x) + dx).rounded())
                guard xr >= 0, xr < width else { continue }
                if abs(other[row + xr] + dx) <= lrTolerance { valid[row + x] = 1 }
            }
        }
        return valid
    }

    /// Disparity with failed matches replaced by the normalized box-filtered
    /// field of the valid ones (falling back to the global shift where no
    /// valid neighbours are near), so the field stays smooth across holes.
    private func filled(_ d: [Float], valid v: [Float], fallback: Float, width: Int, height: Int) -> [Float] {
        let n = width * height
        let count = vDSP_Length(n)
        var weighted = [Float](repeating: 0, count: n)
        vDSP_vmul(d, 1, v, 1, &weighted, 1, count)
        var numerator = [Float](repeating: 0, count: n)
        var denominator = [Float](repeating: 0, count: n)
        let radius = max(8, min(width, height) / 12)
        Vec.boxBlur(weighted, into: &numerator, width: width, height: height, radius: radius)
        Vec.boxBlur(v, into: &denominator, width: width, height: height, radius: radius)
        // field = numerator / denominator where enough neighbours were valid, else fallback
        let field = Vec.ratio(newL: numerator, overL: denominator, floor: 1e-3)
        var enough = [Float](repeating: 0, count: n)
        var minCoverage: Float = 0.05, half: Float = 0.5
        vDSP_vsub([minCoverage], 0, denominator, 1, &enough, 1, count)   // denominator - minCoverage
        vDSP_vthrsc(enough, 1, &half, &half, &enough, 1, count)             // ±0.5 around 0.5 → 0/1
        vDSP_vsadd(enough, 1, &half, &enough, 1, count)
        _ = minCoverage
        var fill = [Float](repeating: fallback, count: n)
        // fill = enough * field + (1 - enough) * fallback
        var diff = [Float](repeating: 0, count: n)
        vDSP_vsub(fill, 1, field, 1, &diff, 1, count)      // field - fallback
        vDSP_vmul(diff, 1, enough, 1, &diff, 1, count)
        vDSP_vadd(fill, 1, diff, 1, &fill, 1, count)
        // out = v * d + (1 - v) * fill
        var out = [Float](repeating: 0, count: n)
        vDSP_vsub(fill, 1, d, 1, &out, 1, count)           // d - fill
        vDSP_vmul(out, 1, v, 1, &out, 1, count)
        vDSP_vadd(fill, 1, out, 1, &out, 1, count)
        return out
    }

    /// Contrast-normalized |reference − warp(other)| after matching local
    /// means, taking the best match within ±`toleranceRadius` pixels. Pixels
    /// whose warp lands outside the image, and a border margin, are zero.
    private func residual(
        reference rawReference: [Float], other rawOther: [Float], disparity: [Float],
        width: Int, height: Int
    ) -> [Float] {
        let n = width * height
        var reference = rawReference
        var other = rawOther
        if smoothingRadius > 0 {
            Vec.boxBlur(rawReference, into: &reference, width: width, height: height, radius: smoothingRadius)
            Vec.boxBlur(rawOther, into: &other, width: width, height: height, radius: smoothingRadius)
        }
        var warped = reference
        var inRange = [Float](repeating: 0, count: n)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let xs = Int((Float(x) + disparity[row + x]).rounded())
                if xs >= 0, xs < width { warped[row + x] = other[row + xs]; inRange[row + x] = 1 }
            }
        }
        // Local exposure normalization: scale the warp by the ratio of local means.
        var meanRef = [Float](repeating: 0, count: n)
        var meanWarp = [Float](repeating: 0, count: n)
        Vec.boxBlur(reference, into: &meanRef, width: width, height: height, radius: normalizationRadius)
        Vec.boxBlur(warped, into: &meanWarp, width: width, height: height, radius: normalizationRadius)
        let gain = Vec.clipped(Vec.ratio(newL: meanRef, overL: meanWarp, floor: 0.01), low: 0.5, high: 2)
        var normalized = [Float](repeating: 0, count: n)
        vDSP_vmul(warped, 1, gain, 1, &normalized, 1, vDSP_Length(n))

        // Best-of-neighbourhood difference: min over small shifts of the warp.
        var residual = [Float](repeating: .greatestFiniteMagnitude, count: n)
        var shifted = [Float](repeating: 0, count: n)
        var diff = [Float](repeating: 0, count: n)
        let t = toleranceRadius
        for dy in -t...t {
            for dx in -t...t {
                Self.shift(normalized, into: &shifted, dx: dx, dy: dy, width: width, height: height)
                vDSP_vsub(shifted, 1, reference, 1, &diff, 1, vDSP_Length(n))
                vDSP_vabs(diff, 1, &diff, 1, vDSP_Length(n))
                vDSP_vmin(diff, 1, residual, 1, &residual, 1, vDSP_Length(n))
            }
        }
        // Normalize by local contrast (mean absolute deviation from the local
        // mean), so busy texture is held to a looser standard than flat areas.
        var deviation = [Float](repeating: 0, count: n)
        vDSP_vsub(meanRef, 1, reference, 1, &deviation, 1, vDSP_Length(n))
        vDSP_vabs(deviation, 1, &deviation, 1, vDSP_Length(n))
        var contrast = [Float](repeating: 0, count: n)
        Vec.boxBlur(deviation, into: &contrast, width: width, height: height, radius: normalizationRadius)
        var floor = contrastFloor
        vDSP_vsadd(contrast, 1, &floor, &contrast, 1, vDSP_Length(n))
        vDSP_vdiv(contrast, 1, residual, 1, &residual, 1, vDSP_Length(n))
        // Zero where the warp fell outside the image and along the border.
        vDSP_vmul(residual, 1, inRange, 1, &residual, 1, vDSP_Length(n))
        let mx = Int(Double(width) * borderFraction), my = Int(Double(height) * borderFraction)
        for y in 0..<height {
            let row = y * width
            if y < my || y >= height - my {
                for x in 0..<width { residual[row + x] = 0 }
            } else {
                for x in 0..<mx { residual[row + x] = 0; residual[row + width - 1 - x] = 0 }
            }
        }
        return residual
    }

    /// Scales the residual toward zero near disparity discontinuities and
    /// zeroes it where too few neighbours matched to trust the fill-in.
    private func suppressOcclusionsAndUnknowns(
        _ residual: inout [Float], disparity: [Float], valid: [Float], width: Int, height: Int
    ) {
        let n = width * height
        let count = vDSP_Length(n)
        // |d(x+1) − d(x−1)| + |d(y+1) − d(y−1)|
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        var grad = [Float](repeating: 0, count: n), tmp = [Float](repeating: 0, count: n)
        Self.shift(disparity, into: &a, dx: 1, dy: 0, width: width, height: height)
        Self.shift(disparity, into: &b, dx: -1, dy: 0, width: width, height: height)
        vDSP_vsub(b, 1, a, 1, &grad, 1, count)
        vDSP_vabs(grad, 1, &grad, 1, count)
        Self.shift(disparity, into: &a, dx: 0, dy: 1, width: width, height: height)
        Self.shift(disparity, into: &b, dx: 0, dy: -1, width: width, height: height)
        vDSP_vsub(b, 1, a, 1, &tmp, 1, count)
        vDSP_vabs(tmp, 1, &tmp, 1, count)
        vDSP_vadd(grad, 1, tmp, 1, &grad, 1, count)
        // weight = clip(1 − grad / occlusionGradient, 0, 1), spread a little
        var scale = -1 / occlusionGradient, one: Float = 1
        vDSP_vsmsa(grad, 1, &scale, &one, &tmp, 1, count)
        let weight = Vec.clipped(tmp)
        var spread = [Float](repeating: 0, count: n)
        Vec.boxBlur(weight, into: &spread, width: width, height: height, radius: 3)
        // Use the more suppressive of the local and spread weights.
        vDSP_vmin(weight, 1, spread, 1, &spread, 1, count)
        vDSP_vmul(residual, 1, spread, 1, &residual, 1, count)

        // Unknown: match coverage over a wide neighbourhood below the floor.
        let known = Self.knownMask(valid: valid, width: width, height: height, coverage: unknownCoverage)
        vDSP_vmul(residual, 1, known, 1, &residual, 1, count)
    }

    /// 1 where enough neighbours matched for the residual to be meaningful.
    /// (Mirrors `suppressOcclusionsAndUnknowns`; used by the overlay.)
    static func knownMask(valid: [Float], width: Int, height: Int, coverage: Float) -> [Float] {
        var cov = [Float](repeating: 0, count: valid.count)
        Vec.boxBlur(valid, into: &cov, width: width, height: height, radius: unknownRadius(width: width, height: height))
        return cov.map { $0 >= coverage ? 1 : 0 }
    }

    /// `dst[x, y] = src[x + dx, y + dy]`, edge-clamped.
    private static func shift(_ src: [Float], into dst: inout [Float], dx: Int, dy: Int, width: Int, height: Int) {
        src.withUnsafeBufferPointer { sp in
            dst.withUnsafeMutableBufferPointer { dp in
                for y in 0..<height {
                    let sy = min(height - 1, max(0, y + dy))
                    let srcRow = sp.baseAddress! + sy * width
                    let dstRow = dp.baseAddress! + y * width
                    let x0 = max(0, -dx), x1 = min(width, width - dx)
                    if x1 > x0 { dstRow.advanced(by: x0).update(from: srcRow.advanced(by: x0 + dx), count: x1 - x0) }
                    for x in 0..<x0 { dstRow[x] = srcRow[0] }
                    for x in max(x0, x1)..<width { dstRow[x] = srcRow[width - 1] }
                }
            }
        }
    }

    private static func cropped(_ plane: [Float], from srcWidth: Int, to width: Int, height: Int) -> [Float] {
        guard srcWidth != width || plane.count != width * height else { return plane }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            out.replaceSubrange(y * width..<(y + 1) * width, with: plane[y * srcWidth..<y * srcWidth + width])
        }
        return out
    }

    // MARK: - Visualization

    /// The eye with residual ≥ `threshold` painted red and pixels whose
    /// match failed the left-right check faintly tinted blue, at full size.
    static func residualOverlay(_ result: Result, on image: CGImage, left: Bool, threshold: Float) -> CGImage? {
        let residual = left ? result.residualLeft : result.residualRight
        let valid = left ? result.validLeft : result.validRight
        let known = knownMask(valid: valid, width: result.width, height: result.height, coverage: StereoResidual().unknownCoverage)
        return paint(on: image, analysisWidth: result.width, analysisHeight: result.height) { i in
            if residual[i] >= threshold { return (255, 0, 0, 0.75) }
            return known[i] == 0 ? (0, 0, 160, 0.25) : nil
        }
    }

    /// Disparity as a grayscale map (near = bright), invalid pixels blue.
    static func disparityImage(_ result: Result, left: Bool) -> CGImage? {
        let d = left ? result.disparityLeft : result.disparityRight
        let valid = left ? result.validLeft : result.validRight
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        for i in 0..<d.count where valid[i] > 0 { lo = min(lo, d[i]); hi = max(hi, d[i]) }
        let range = max(1, hi - lo)
        let w = result.width, h = result.height
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let b = i * 4
            if valid[i] > 0 {
                let v = UInt8(max(0, min(255, (d[i] - lo) / range * 255)))
                rgba[b] = v; rgba[b + 1] = v; rgba[b + 2] = v
            } else {
                rgba[b] = 30; rgba[b + 1] = 40; rgba[b + 2] = 160
            }
        }
        return Vec.rgbaImage(rgba, width: w, height: h)
    }

    /// Paints per-analysis-pixel colors (with alpha) over a full-size image,
    /// nearest-neighbour upsampled.
    private static func paint(
        on image: CGImage, analysisWidth: Int, analysisHeight: Int,
        color: (Int) -> (r: Int, g: Int, b: Int, a: Float)?
    ) -> CGImage? {
        guard var rgba = Vec.rgba(of: image) else { return nil }
        let width = image.width, height = image.height
        for y in 0..<height {
            let sy = min(analysisHeight - 1, y * analysisHeight / height)
            for x in 0..<width {
                let sx = min(analysisWidth - 1, x * analysisWidth / width)
                guard let c = color(sy * analysisWidth + sx) else { continue }
                let b = (y * width + x) * 4
                let keep = 1 - c.a
                rgba[b] = UInt8(Float(rgba[b]) * keep + Float(c.r) * c.a)
                rgba[b + 1] = UInt8(Float(rgba[b + 1]) * keep + Float(c.g) * c.a)
                rgba[b + 2] = UInt8(Float(rgba[b + 2]) * keep + Float(c.b) * c.a)
            }
        }
        return Vec.rgbaImage(rgba, width: width, height: height)
    }
}
