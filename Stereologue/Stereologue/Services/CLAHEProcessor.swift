import CoreImage
import CoreGraphics

// `nonisolated` so this pure-value computation is callable from any actor —
// `RestorationPipeline` (an actor) invokes it on its serial queue.
nonisolated struct CLAHEProcessor {

    var tileSize: Int = 128
    var clipLimit: Float = 2.0

    private let histogramBins = 256

    func apply(to image: CIImage, context: CIContext) -> CIImage {
        guard let cgImage = context.createCGImage(image, from: image.extent),
              let pixels = extractRGBA(from: cgImage) else {
            return image
        }

        let width = cgImage.width
        let height = cgImage.height
        let pixelCount = width * height

        // Extract luminance (Rec. 709)
        var luminance = [Float](repeating: 0, count: pixelCount)
        for i in 0..<pixelCount {
            let r = Float(pixels[i * 4]) / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            luminance[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }

        let cols = max(1, Int(round(Double(width) / Double(tileSize))))
        let rows = max(1, Int(round(Double(height) / Double(tileSize))))

        // Build clipped CDF for each tile
        var tileCDFs = [[Float]]()
        tileCDFs.reserveCapacity(rows * cols)

        for tileRow in 0..<rows {
            for tileCol in 0..<cols {
                let x0 = tileCol * width / cols
                let x1 = (tileCol + 1) * width / cols
                let y0 = tileRow * height / rows
                let y1 = (tileRow + 1) * height / rows
                let tilePixelCount = (x1 - x0) * (y1 - y0)

                var histogram = [Float](repeating: 0, count: histogramBins)
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let lum = luminance[y * width + x]
                        let bin = min(histogramBins - 1, max(0, Int(lum * Float(histogramBins - 1))))
                        histogram[bin] += 1
                    }
                }

                // Clip and redistribute
                let avgBinHeight = Float(tilePixelCount) / Float(histogramBins)
                let clipThreshold = clipLimit * avgBinHeight
                var excess: Float = 0
                for i in 0..<histogramBins {
                    if histogram[i] > clipThreshold {
                        excess += histogram[i] - clipThreshold
                        histogram[i] = clipThreshold
                    }
                }
                let redistribution = excess / Float(histogramBins)
                for i in 0..<histogramBins {
                    histogram[i] += redistribution
                }

                // CDF
                var cdf = [Float](repeating: 0, count: histogramBins)
                cdf[0] = histogram[0]
                for i in 1..<histogramBins {
                    cdf[i] = cdf[i - 1] + histogram[i]
                }
                if let cdfMax = cdf.last, cdfMax > 0 {
                    for i in 0..<histogramBins {
                        cdf[i] /= cdfMax
                    }
                }

                tileCDFs.append(cdf)
            }
        }

        // Apply with bilinear interpolation between tile CDFs
        var output = [UInt8](repeating: 0, count: pixelCount * 4)

        for y in 0..<height {
            for x in 0..<width {
                let idx = y * width + x
                let lum = luminance[idx]
                let bin = min(histogramBins - 1, max(0, Int(lum * Float(histogramBins - 1))))

                // Position relative to tile centers
                let tileX = Float(x) * Float(cols) / Float(width) - 0.5
                let tileY = Float(y) * Float(rows) / Float(height) - 0.5

                let col0 = max(0, min(cols - 1, Int(floor(tileX))))
                let col1 = max(0, min(cols - 1, col0 + 1))
                let row0 = max(0, min(rows - 1, Int(floor(tileY))))
                let row1 = max(0, min(rows - 1, row0 + 1))

                let fx = max(0, min(1, tileX - Float(col0)))
                let fy = max(0, min(1, tileY - Float(row0)))

                let v00 = tileCDFs[row0 * cols + col0][bin]
                let v01 = tileCDFs[row0 * cols + col1][bin]
                let v10 = tileCDFs[row1 * cols + col0][bin]
                let v11 = tileCDFs[row1 * cols + col1][bin]

                let top = v00 * (1 - fx) + v01 * fx
                let bottom = v10 * (1 - fx) + v11 * fx
                let newLum = top * (1 - fy) + bottom * fy

                let srcBase = idx * 4
                if lum > 0.001 {
                    let scale = newLum / lum
                    output[srcBase] = clampByte(Float(pixels[srcBase]) * scale)
                    output[srcBase + 1] = clampByte(Float(pixels[srcBase + 1]) * scale)
                    output[srcBase + 2] = clampByte(Float(pixels[srcBase + 2]) * scale)
                } else {
                    let mapped = UInt8(min(255, max(0, Int(newLum * 255))))
                    output[srcBase] = mapped
                    output[srcBase + 1] = mapped
                    output[srcBase + 2] = mapped
                }
                output[srcBase + 3] = pixels[srcBase + 3]
            }
        }

        guard let outCG = makeCGImage(
            from: output, width: width, height: height,
            colorSpace: cgImage.colorSpace
        ) else {
            return image
        }

        return CIImage(cgImage: outCG)
    }

    // MARK: - Pixel Helpers

    private func extractRGBA(from cgImage: CGImage) -> [UInt8]? {
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

    private func makeCGImage(
        from pixels: [UInt8], width: Int, height: Int, colorSpace: CGColorSpace?
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

    private func clampByte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, Int(value))))
    }
}
