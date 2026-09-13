//
//  PixelPlanes.swift
//  Stereologue
//
//  Planar Float32 RGB working buffer for the restoration kernels, backed by
//  vImage / vDSP so every whole-image operation is one library call instead
//  of a Swift per-pixel loop. That keeps the pipeline fast in Debug builds
//  too, where scalar Swift loops run 20× slower than in Release.
//

import Accelerate
import CoreGraphics
import Foundation

/// Planar Float32 RGB in 0…1 plus the untouched alpha bytes.
nonisolated struct PixelPlanes {
    var r: [Float]
    var g: [Float]
    var b: [Float]
    let alpha: [UInt8]
    let width: Int
    let height: Int
    var count: Int { width * height }

    static let lumaR: Float = 0.2126
    static let lumaG: Float = 0.7152
    static let lumaB: Float = 0.0722

    /// Deinterleaves an RGBA8 buffer.
    init(rgba: [UInt8], width: Int, height: Int) {
        let n = width * height
        var r8 = [UInt8](repeating: 0, count: n)
        var g8 = [UInt8](repeating: 0, count: n)
        var b8 = [UInt8](repeating: 0, count: n)
        var a8 = [UInt8](repeating: 0, count: n)
        rgba.withUnsafeBufferPointer { src in
            r8.withUnsafeMutableBufferPointer { rp in
            g8.withUnsafeMutableBufferPointer { gp in
            b8.withUnsafeMutableBufferPointer { bp in
            a8.withUnsafeMutableBufferPointer { ap in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                    height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4
                )
                var rb = Self.planar8(rp.baseAddress!, width, height)
                var gb = Self.planar8(gp.baseAddress!, width, height)
                var bb = Self.planar8(bp.baseAddress!, width, height)
                var ab = Self.planar8(ap.baseAddress!, width, height)
                vImageConvert_ARGB8888toPlanar8(&source, &rb, &gb, &bb, &ab, vImage_Flags(kvImageNoFlags))
            }}}}
        }
        self.width = width
        self.height = height
        r = Vec.toFloat(r8)
        g = Vec.toFloat(g8)
        b = Vec.toFloat(b8)
        alpha = a8
    }

    /// Re-interleaves to RGBA8, clipping to 0…1 first.
    func rgba() -> [UInt8] {
        let n = count
        let r8 = Vec.toBytes(r), g8 = Vec.toBytes(g), b8 = Vec.toBytes(b)
        var out = [UInt8](repeating: 0, count: n * 4)
        r8.withUnsafeBufferPointer { rp in
        g8.withUnsafeBufferPointer { gp in
        b8.withUnsafeBufferPointer { bp in
        alpha.withUnsafeBufferPointer { ap in
        out.withUnsafeMutableBufferPointer { op in
            var rb = Self.planar8(UnsafeMutablePointer(mutating: rp.baseAddress!), width, height)
            var gb = Self.planar8(UnsafeMutablePointer(mutating: gp.baseAddress!), width, height)
            var bb = Self.planar8(UnsafeMutablePointer(mutating: bp.baseAddress!), width, height)
            var ab = Self.planar8(UnsafeMutablePointer(mutating: ap.baseAddress!), width, height)
            var dest = vImage_Buffer(
                data: op.baseAddress!, height: vImagePixelCount(height),
                width: vImagePixelCount(width), rowBytes: width * 4
            )
            vImageConvert_Planar8toARGB8888(&rb, &gb, &bb, &ab, &dest, vImage_Flags(kvImageNoFlags))
        }}}}}
        return out
    }

    /// Rec. 709 luminance plane.
    func luminance() -> [Float] {
        let n = vDSP_Length(count)
        var l = [Float](repeating: 0, count: count)
        var kr = Self.lumaR, kg = Self.lumaG, kb = Self.lumaB
        vDSP_vsmul(r, 1, &kr, &l, 1, n)
        vDSP_vsma(g, 1, &kg, l, 1, &l, 1, n)
        vDSP_vsma(b, 1, &kb, l, 1, &l, 1, n)
        return l
    }

    /// Multiplies every channel by a per-pixel factor, then clips to 0…1.
    /// This is how every luminance-domain stage preserves hue and saturation.
    mutating func multiply(by ratio: [Float]) {
        let n = vDSP_Length(count)
        vDSP_vmul(r, 1, ratio, 1, &r, 1, n)
        vDSP_vmul(g, 1, ratio, 1, &g, 1, n)
        vDSP_vmul(b, 1, ratio, 1, &b, 1, n)
        clip()
    }

    /// Per-channel gains (white balance), then clips to 0…1.
    mutating func multiply(r gr: Float, g gg: Float, b gb: Float) {
        let n = vDSP_Length(count)
        var gr = gr, gg = gg, gb = gb
        vDSP_vsmul(r, 1, &gr, &r, 1, n)
        vDSP_vsmul(g, 1, &gg, &g, 1, n)
        vDSP_vsmul(b, 1, &gb, &b, 1, n)
        clip()
    }

    /// Maps each channel through a 256-entry lookup table (linearly
    /// interpolated), e.g. a per-channel contrast stretch.
    mutating func apply(tables tr: [Float], _ tg: [Float], _ tb: [Float]) {
        r = Vec.lookup(r, table: tr)
        g = Vec.lookup(g, table: tg)
        b = Vec.lookup(b, table: tb)
    }

    mutating func clip() {
        r = Vec.clipped(r)
        g = Vec.clipped(g)
        b = Vec.clipped(b)
    }

    private static func planar8(_ data: UnsafeMutablePointer<UInt8>, _ width: Int, _ height: Int) -> vImage_Buffer {
        vImage_Buffer(data: data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
    }
}

/// Small vDSP/vImage/vForce wrappers used by the restoration kernels.
nonisolated enum Vec {

    /// Bytes → 0…1 floats.
    static func toFloat(_ bytes: [UInt8]) -> [Float] {
        let n = vDSP_Length(bytes.count)
        var out = [Float](repeating: 0, count: bytes.count)
        vDSP_vfltu8(bytes, 1, &out, 1, n)
        var scale: Float = 1 / 255
        vDSP_vsmul(out, 1, &scale, &out, 1, n)
        return out
    }

    /// 0…1 floats → bytes, rounding, after clipping.
    static func toBytes(_ values: [Float]) -> [UInt8] {
        let n = vDSP_Length(values.count)
        var scaled = clipped(values)
        var scale: Float = 255
        vDSP_vsmul(scaled, 1, &scale, &scaled, 1, n)
        var out = [UInt8](repeating: 0, count: values.count)
        vDSP_vfixru8(scaled, 1, &out, 1, n)
        return out
    }

    static func clipped(_ values: [Float], low: Float = 0, high: Float = 1) -> [Float] {
        var lo = low, hi = high
        var out = [Float](repeating: 0, count: values.count)
        vDSP_vclip(values, 1, &lo, &hi, &out, 1, vDSP_Length(values.count))
        return out
    }

    /// Every `stride`-th element, as a contiguous array (for statistics that
    /// need a contiguous input such as `pow`).
    static func sampled(_ values: [Float], stride: Int) -> [Float] {
        guard stride > 1 else { return values }
        let n = (values.count + stride - 1) / stride
        var out = [Float](repeating: 0, count: n)
        var one: Float = 1
        vDSP_vsmul(values, stride, &one, &out, 1, vDSP_Length(n))
        return out
    }

    static func mean(_ values: [Float], stride: Int = 1) -> Float {
        let n = vDSP_Length((values.count + stride - 1) / stride)
        var m: Float = 0
        vDSP_meanv(values, stride, &m, n)
        return m
    }

    static func meanOfSquares(_ values: [Float], stride: Int = 1) -> Float {
        let n = vDSP_Length((values.count + stride - 1) / stride)
        var m: Float = 0
        vDSP_measqv(values, stride, &m, n)
        return m
    }

    /// Fraction of (strided) elements at or above `threshold`.
    static func fraction(of values: [Float], atLeast threshold: Float, stride: Int = 1) -> Float {
        let n = (values.count + stride - 1) / stride
        guard n > 0 else { return 0 }
        var thr = threshold, one: Float = 1
        var signs = [Float](repeating: 0, count: n)
        vDSP_vthrsc(values, stride, &thr, &one, &signs, 1, vDSP_Length(n))
        var sum: Float = 0
        vDSP_sve(signs, 1, &sum, vDSP_Length(n))
        return (sum / 1 + Float(n)) / 2 / Float(n)
    }

    static func pow(_ values: [Float], _ exponent: Float) -> [Float] {
        var n = Int32(values.count)
        var exponents = [Float](repeating: exponent, count: values.count)
        var out = [Float](repeating: 0, count: values.count)
        vvpowf(&out, &exponents, values, &n)
        return out
    }

    static func log(_ values: [Float]) -> [Float] {
        var n = Int32(values.count)
        var out = [Float](repeating: 0, count: values.count)
        vvlogf(&out, values, &n)
        return out
    }

    static func exp(_ values: [Float]) -> [Float] {
        var n = Int32(values.count)
        var out = [Float](repeating: 0, count: values.count)
        vvexpf(&out, values, &n)
        return out
    }

    /// `values * scale + offset`.
    static func affine(_ values: [Float], scale: Float, offset: Float) -> [Float] {
        var s = scale, o = offset
        var out = [Float](repeating: 0, count: values.count)
        vDSP_vsmsa(values, 1, &s, &o, &out, 1, vDSP_Length(values.count))
        return out
    }

    /// `newL / max(l, floor)`: the per-pixel factor that carries a luminance
    /// remap onto all three channels.
    static func ratio(newL: [Float], overL l: [Float], floor: Float = 0.001) -> [Float] {
        let n = vDSP_Length(l.count)
        var fl = floor
        var safe = [Float](repeating: 0, count: l.count)
        vDSP_vthr(l, 1, &fl, &safe, 1, n)
        var out = [Float](repeating: 0, count: l.count)
        vDSP_vdiv(safe, 1, newL, 1, &out, 1, n)
        return out
    }

    /// 256-bin histogram of a 0…1 plane (bin = floor(v × 255), like the
    /// byte histogram the kernels were written against).
    static func histogram256(_ values: [Float], width: Int, height: Int, rowStart: Int = 0, rowBytesFloats: Int? = nil) -> [Int] {
        var hist = [vImagePixelCount](repeating: 0, count: 256)
        values.withUnsafeBufferPointer { src in
            var buffer = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: src.baseAddress! + rowStart),
                height: vImagePixelCount(height), width: vImagePixelCount(width),
                rowBytes: (rowBytesFloats ?? width) * MemoryLayout<Float>.size
            )
            hist.withUnsafeMutableBufferPointer { h in
                vImageHistogramCalculation_PlanarF(&buffer, h.baseAddress!, 256, 0, 256.0 / 255.0, vImage_Flags(kvImageNoFlags))
            }
        }
        return hist.map { Int($0) }
    }

    /// Maps 0…1 values through a 256-entry table with linear interpolation.
    static func lookup(_ values: [Float], table: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        lookup(values, into: &out, table: table, width: values.count, height: 1)
        return out
    }

    /// Table lookup over a `width`×`height` sub-rectangle whose rows start
    /// `srcRowStride` floats apart (and likewise `dstRowStride`).
    static func lookup(
        _ values: [Float], srcStart: Int = 0, srcRowStride: Int? = nil,
        into out: inout [Float], dstStart: Int = 0, dstRowStride: Int? = nil,
        table: [Float], width: Int, height: Int
    ) {
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: src.baseAddress! + srcStart),
                    height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: (srcRowStride ?? width) * MemoryLayout<Float>.size
                )
                var dest = vImage_Buffer(
                    data: dst.baseAddress! + dstStart,
                    height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: (dstRowStride ?? width) * MemoryLayout<Float>.size
                )
                table.withUnsafeBufferPointer { t in
                    vImageInterpolatedLookupTable_PlanarF(&source, &dest, t.baseAddress!, vImagePixelCount(t.count), 1, 0, vImage_Flags(kvImageNoFlags))
                }
            }
        }
    }
}
