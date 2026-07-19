import Foundation

// `nonisolated` so this pure-value computation is callable from any actor —
// `RestorationPipeline` (an actor) invokes it on its serial queue.
nonisolated struct CLAHEProcessor {

    var tileSize: Int = 128
    var clipLimit: Float = 2.0

    private let histogramBins = 256

    /// Applies CLAHE in place on an interleaved RGBA8 buffer, enhancing
    /// luminance while preserving color (RGB is scaled by the luminance ratio).
    ///
    /// Operating directly on the caller's buffer avoids the CGImage↔buffer
    /// conversions the old CIImage-based entry point performed on every call.
    func apply(to pixels: inout [UInt8], width: Int, height: Int) {
        let pixelCount = width * height
        guard pixelCount > 0 else { return }

        // Extract luminance (Rec. 709) once, up front.
        var luminance = [Float](repeating: 0, count: pixelCount)
        pixels.withUnsafeBufferPointer { src in
            luminance.withUnsafeMutableBufferPointer { lum in
                for i in 0..<pixelCount {
                    let base = i * 4
                    let r = Float(src[base]) / 255.0
                    let g = Float(src[base + 1]) / 255.0
                    let b = Float(src[base + 2]) / 255.0
                    lum[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
                }
            }
        }

        let cols = max(1, Int(round(Double(width) / Double(tileSize))))
        let rows = max(1, Int(round(Double(height) / Double(tileSize))))

        // Flattened per-tile CDFs: index = (tileRow * cols + tileCol) * bins + bin.
        // A single contiguous buffer replaces the old array-of-arrays, so the
        // per-pixel apply loop does flat, pointer-based lookups.
        var tileCDFs = [Float](repeating: 0, count: rows * cols * histogramBins)
        var histogram = [Float](repeating: 0, count: histogramBins)

        for tileRow in 0..<rows {
            for tileCol in 0..<cols {
                let x0 = tileCol * width / cols
                let x1 = (tileCol + 1) * width / cols
                let y0 = tileRow * height / rows
                let y1 = (tileRow + 1) * height / rows
                let tilePixelCount = (x1 - x0) * (y1 - y0)

                for j in 0..<histogramBins { histogram[j] = 0 }
                luminance.withUnsafeBufferPointer { lum in
                    for y in y0..<y1 {
                        let rowBase = y * width
                        for x in x0..<x1 {
                            let l = lum[rowBase + x]
                            let bin = min(histogramBins - 1, max(0, Int(l * Float(histogramBins - 1))))
                            histogram[bin] += 1
                        }
                    }
                }

                // Clip and redistribute the excess uniformly.
                let avgBinHeight = Float(tilePixelCount) / Float(histogramBins)
                let clipThreshold = clipLimit * avgBinHeight
                var excess: Float = 0
                for j in 0..<histogramBins {
                    if histogram[j] > clipThreshold {
                        excess += histogram[j] - clipThreshold
                        histogram[j] = clipThreshold
                    }
                }
                let redistribution = excess / Float(histogramBins)

                // Cumulative distribution, normalized to 0...1.
                let tileBase = (tileRow * cols + tileCol) * histogramBins
                tileCDFs.withUnsafeMutableBufferPointer { cdf in
                    var running: Float = 0
                    for j in 0..<histogramBins {
                        running += histogram[j] + redistribution
                        cdf[tileBase + j] = running
                    }
                    if running > 0 {
                        for j in 0..<histogramBins {
                            cdf[tileBase + j] /= running
                        }
                    }
                }
            }
        }

        // Apply with bilinear interpolation between the four nearest tile CDFs.
        pixels.withUnsafeMutableBufferPointer { out in
            luminance.withUnsafeBufferPointer { lum in
                tileCDFs.withUnsafeBufferPointer { cdf in
                    for y in 0..<height {
                        let tileY = Float(y) * Float(rows) / Float(height) - 0.5
                        let row0 = max(0, min(rows - 1, Int(floor(tileY))))
                        let row1 = max(0, min(rows - 1, row0 + 1))
                        let fy = max(0, min(1, tileY - Float(row0)))
                        let rowBase = y * width

                        for x in 0..<width {
                            let idx = rowBase + x
                            let l = lum[idx]
                            let bin = min(histogramBins - 1, max(0, Int(l * Float(histogramBins - 1))))

                            let tileX = Float(x) * Float(cols) / Float(width) - 0.5
                            let col0 = max(0, min(cols - 1, Int(floor(tileX))))
                            let col1 = max(0, min(cols - 1, col0 + 1))
                            let fx = max(0, min(1, tileX - Float(col0)))

                            let v00 = cdf[(row0 * cols + col0) * histogramBins + bin]
                            let v01 = cdf[(row0 * cols + col1) * histogramBins + bin]
                            let v10 = cdf[(row1 * cols + col0) * histogramBins + bin]
                            let v11 = cdf[(row1 * cols + col1) * histogramBins + bin]

                            let top = v00 * (1 - fx) + v01 * fx
                            let bottom = v10 * (1 - fx) + v11 * fx
                            let newLum = top * (1 - fy) + bottom * fy

                            let base = idx * 4
                            if l > 0.001 {
                                let scale = newLum / l
                                out[base] = clampByte(Float(out[base]) * scale)
                                out[base + 1] = clampByte(Float(out[base + 1]) * scale)
                                out[base + 2] = clampByte(Float(out[base + 2]) * scale)
                            } else {
                                let mapped = UInt8(min(255, max(0, Int(newLum * 255))))
                                out[base] = mapped
                                out[base + 1] = mapped
                                out[base + 2] = mapped
                            }
                        }
                    }
                }
            }
        }
    }

    private func clampByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value))))
    }
}
