//
//  CLAHEProcessor.swift
//  Stereologue
//
//  Contrast-limited adaptive histogram equalization on a luminance plane.
//

import Accelerate
import Foundation

/// Tiled, clip-limited histogram equalization with bilinear blending between
/// the four nearest tile mappings, computed with vImage table lookups and
/// vDSP blends per region rather than a per-pixel Swift loop.
///
/// `nonisolated` so `RestorationPipeline` can call it off the main actor.
nonisolated struct CLAHEProcessor {

    var tileSize: Int = 128
    var clipLimit: Float = 2.0

    private let bins = 256

    /// Returns the equalized luminance for `lum` (0…1, row-major
    /// `width`×`height`). Callers apply it as a ratio so color is preserved.
    func equalized(_ lum: [Float], width: Int, height: Int) -> [Float] {
        let pixelCount = width * height
        guard pixelCount > 0 else { return lum }

        let cols = max(1, Int((Double(width) / Double(tileSize)).rounded()))
        let rows = max(1, Int((Double(height) / Double(tileSize)).rounded()))

        // One normalized CDF (as a 256-entry lookup table) per tile.
        var tables = [[Float]](repeating: [], count: rows * cols)
        for tileRow in 0..<rows {
            for tileCol in 0..<cols {
                let x0 = tileCol * width / cols, x1 = (tileCol + 1) * width / cols
                let y0 = tileRow * height / rows, y1 = (tileRow + 1) * height / rows
                var histogram = Vec.histogram256(
                    lum, width: x1 - x0, height: y1 - y0,
                    rowStart: y0 * width + x0, rowBytesFloats: width
                ).map(Float.init)

                // Clip and redistribute the excess uniformly.
                let avgBinHeight = Float((x1 - x0) * (y1 - y0)) / Float(bins)
                let clipThreshold = clipLimit * avgBinHeight
                var excess: Float = 0
                for j in 0..<bins where histogram[j] > clipThreshold {
                    excess += histogram[j] - clipThreshold
                    histogram[j] = clipThreshold
                }
                let redistribution = excess / Float(bins)

                var cdf = [Float](repeating: 0, count: bins)
                var running: Float = 0
                for j in 0..<bins {
                    running += histogram[j] + redistribution
                    cdf[j] = running
                }
                if running > 0 {
                    var inv = 1 / running
                    vDSP_vsmul(cdf, 1, &inv, &cdf, 1, vDSP_Length(bins))
                }
                tables[tileRow * cols + tileCol] = cdf
            }
        }

        // Bilinear interpolation weights, separable: each pixel's column picks
        // (col0, col1, fx) and its row picks (row0, row1, fy). Regions where
        // those tile indices are constant are rectangles, so within one region
        // the four lookup tables are fixed and the blend is a vector op.
        let colSpans = Self.spans(count: width, tiles: cols)
        let rowSpans = Self.spans(count: height, tiles: rows)

        var out = [Float](repeating: 0, count: pixelCount)
        for rowSpan in rowSpans {
            let h = rowSpan.end - rowSpan.start
            // fy per row of this span, replicated across the region width later.
            let fy = (rowSpan.start..<rowSpan.end).map { rowSpan.weight($0) }
            for colSpan in colSpans {
                let w = colSpan.end - colSpan.start
                let n = w * h
                let t00 = tables[rowSpan.tile0 * cols + colSpan.tile0]
                let t01 = tables[rowSpan.tile0 * cols + colSpan.tile1]
                let t10 = tables[rowSpan.tile1 * cols + colSpan.tile0]
                let t11 = tables[rowSpan.tile1 * cols + colSpan.tile1]
                let srcStart = rowSpan.start * width + colSpan.start

                var v00 = [Float](repeating: 0, count: n)
                var v01 = [Float](repeating: 0, count: n)
                var v10 = [Float](repeating: 0, count: n)
                var v11 = [Float](repeating: 0, count: n)
                Vec.lookup(lum, srcStart: srcStart, srcRowStride: width, into: &v00, table: t00, width: w, height: h)
                Vec.lookup(lum, srcStart: srcStart, srcRowStride: width, into: &v01, table: t01, width: w, height: h)
                Vec.lookup(lum, srcStart: srcStart, srcRowStride: width, into: &v10, table: t10, width: w, height: h)
                Vec.lookup(lum, srcStart: srcStart, srcRowStride: width, into: &v11, table: t11, width: w, height: h)

                // Weight planes for the region: wx varies by column, wy by row.
                let fxRow = (colSpan.start..<colSpan.end).map { colSpan.weight($0) }
                var wx = [Float](repeating: 0, count: n)
                var wy = [Float](repeating: 0, count: n)
                for row in 0..<h {
                    fxRow.withUnsafeBufferPointer { src in
                        wx.withUnsafeMutableBufferPointer { dst in
                            dst.baseAddress!.advanced(by: row * w).update(from: src.baseAddress!, count: w)
                        }
                    }
                    var f = fy[row]
                    wy.withUnsafeMutableBufferPointer { dst in
                        vDSP_vfill(&f, dst.baseAddress!.advanced(by: row * w), 1, vDSP_Length(w))
                    }
                }

                // top = v00 + (v01 - v00) * wx ; bottom = v10 + (v11 - v10) * wx
                // result = top + (bottom - top) * wy
                let count = vDSP_Length(n)
                vDSP_vsub(v00, 1, v01, 1, &v01, 1, count)      // v01 := v01 - v00
                vDSP_vmul(v01, 1, wx, 1, &v01, 1, count)
                vDSP_vadd(v00, 1, v01, 1, &v00, 1, count)      // v00 := top
                vDSP_vsub(v10, 1, v11, 1, &v11, 1, count)
                vDSP_vmul(v11, 1, wx, 1, &v11, 1, count)
                vDSP_vadd(v10, 1, v11, 1, &v10, 1, count)      // v10 := bottom
                vDSP_vsub(v00, 1, v10, 1, &v10, 1, count)      // v10 := bottom - top
                vDSP_vmul(v10, 1, wy, 1, &v10, 1, count)
                vDSP_vadd(v00, 1, v10, 1, &v00, 1, count)      // v00 := result

                v00.withUnsafeBufferPointer { src in
                    out.withUnsafeMutableBufferPointer { dst in
                        for row in 0..<h {
                            dst.baseAddress!.advanced(by: (rowSpan.start + row) * width + colSpan.start)
                                .update(from: src.baseAddress!.advanced(by: row * w), count: w)
                        }
                    }
                }
            }
        }
        return out
    }

    /// A run of pixel indices that share the same two neighbouring tiles.
    private struct Span {
        let start: Int
        let end: Int
        let tile0: Int
        let tile1: Int
        let tiles: Int
        let extent: Int
        /// Interpolation weight toward `tile1` for pixel `i`.
        func weight(_ i: Int) -> Float {
            let t = Float(i) * Float(tiles) / Float(extent) - 0.5
            return max(0, min(1, t - Float(tile0)))
        }
    }

    private static func spans(count: Int, tiles: Int) -> [Span] {
        var spans: [Span] = []
        var start = 0
        var current: (Int, Int)?
        func tilesFor(_ i: Int) -> (Int, Int) {
            let t = Float(i) * Float(tiles) / Float(count) - 0.5
            let t0 = max(0, min(tiles - 1, Int(t.rounded(.down))))
            let t1 = max(0, min(tiles - 1, t0 + 1))
            return (t0, t1)
        }
        for i in 0..<count {
            let pair = tilesFor(i)
            if let c = current, c != pair {
                spans.append(Span(start: start, end: i, tile0: c.0, tile1: c.1, tiles: tiles, extent: count))
                start = i
            }
            current = pair
        }
        if let c = current {
            spans.append(Span(start: start, end: count, tile0: c.0, tile1: c.1, tiles: tiles, extent: count))
        }
        return spans
    }
}
