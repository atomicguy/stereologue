import CoreImage
import CoreGraphics
import Metal
import OSLog

enum RestorationStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case gentle
    case colorPreserved

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .gentle: "Gentle"
        case .colorPreserved: "Preserve Color"
        }
    }
}

actor RestorationPipeline {

    private let logger = Logger(
        subsystem: "net.atompowered.Stereologue",
        category: "Restoration"
    )

    private let ciContext: CIContext

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [
                .workingFormat: CIFormat.RGBAh
            ])
        } else {
            ciContext = CIContext()
        }
    }

    func restore(_ cgImage: CGImage, style: RestorationStyle = .standard) -> CGImage {
        var image = ingest(cgImage)
        image = neutralizeSepia(image)
        image = stretchContrast(image)

        // Capture color reference after sepia/contrast adjustment but before
        // luminance enhancement. Used by the colorPreserved style to reapply
        // the color/brightness palette on top of the enhanced luminance.
        let colorReference = image

        var clahe = CLAHEProcessor()
        switch style {
        case .standard, .colorPreserved:
            clahe.tileSize = 128
            clahe.clipLimit = 2.0
        case .gentle:
            clahe.tileSize = 192
            clahe.clipLimit = 1.3
        }
        image = clahe.apply(to: image, context: ciContext)
        image = applyToneCurve(image)

        if style == .colorPreserved {
            image = transferLuminance(
                luminanceSource: image,
                colorSource: colorReference
            )
        }

        // SCUNet denoising will be inserted here

        guard let result = ciContext.createCGImage(image, from: image.extent) else {
            logger.warning("Restoration render failed, returning original")
            return cgImage
        }
        return result
    }

    // MARK: - Stage 1: Ingest & Normalize

    private func ingest(_ cgImage: CGImage) -> CIImage {
        let sourceSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CIImage(cgImage: cgImage, options: [.colorSpace: sourceSpace])
    }

    // MARK: - Stage 2a: Sepia / Color Cast Neutralization

    private func neutralizeSepia(_ image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorPolynomial") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0.0, y: 0.92, z: 0.0, w: 0.0), forKey: "inputRedCoefficients")
        filter.setValue(CIVector(x: 0.0, y: 1.00, z: 0.0, w: 0.0), forKey: "inputGreenCoefficients")
        filter.setValue(CIVector(x: 0.02, y: 1.06, z: 0.0, w: 0.0), forKey: "inputBlueCoefficients")
        return filter.outputImage ?? image
    }

    // MARK: - Stage 2b: Black & White Point Stretch

    private func stretchContrast(_ image: CIImage) -> CIImage {
        let extent = image.extent

        guard let minFilter = CIFilter(name: "CIAreaMinimum", parameters: [
                  kCIInputImageKey: image,
                  "inputExtent": CIVector(cgRect: extent)
              ]),
              let maxFilter = CIFilter(name: "CIAreaMaximum", parameters: [
                  kCIInputImageKey: image,
                  "inputExtent": CIVector(cgRect: extent)
              ]),
              let minOutput = minFilter.outputImage,
              let maxOutput = maxFilter.outputImage else {
            return image
        }

        var minPixel = [Float](repeating: 0, count: 4)
        var maxPixel = [Float](repeating: 0, count: 4)
        let linearSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

        ciContext.render(
            minOutput, toBitmap: &minPixel,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: minOutput.extent,
            format: .RGBAf, colorSpace: linearSpace
        )
        ciContext.render(
            maxOutput, toBitmap: &maxPixel,
            rowBytes: 4 * MemoryLayout<Float>.size,
            bounds: maxOutput.extent,
            format: .RGBAf, colorSpace: linearSpace
        )

        let rRange = max(maxPixel[0] - minPixel[0], 1e-6)
        let gRange = max(maxPixel[1] - minPixel[1], 1e-6)
        let bRange = max(maxPixel[2] - minPixel[2], 1e-6)

        // Skip if already well-distributed
        if minPixel[0] < 0.02 && maxPixel[0] > 0.98
            && minPixel[1] < 0.02 && maxPixel[1] > 0.98
            && minPixel[2] < 0.02 && maxPixel[2] > 0.98
        {
            return image
        }

        guard let matrix = CIFilter(name: "CIColorMatrix") else { return image }
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: CGFloat(1 / rRange), y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: CGFloat(1 / gRange), z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: CGFloat(1 / bRange), w: 0), forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(
            x: CGFloat(-minPixel[0] / rRange),
            y: CGFloat(-minPixel[1] / gRange),
            z: CGFloat(-minPixel[2] / bRange),
            w: 0
        ), forKey: "inputBiasVector")

        return matrix.outputImage ?? image
    }

    // MARK: - Stage 2d: Global Tone Curve

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

    // MARK: - Color Transfer (Preserve Color style)

    /// Scales the color reference image so that its per-pixel luminance matches
    /// the enhanced image, leaving hue/saturation untouched.
    private func transferLuminance(
        luminanceSource: CIImage,
        colorSource: CIImage
    ) -> CIImage {
        let extent = luminanceSource.extent
        guard let lumCG = ciContext.createCGImage(luminanceSource, from: extent),
              let colorCG = ciContext.createCGImage(colorSource, from: extent),
              lumCG.width == colorCG.width,
              lumCG.height == colorCG.height,
              let lumPixels = readRGBA(lumCG),
              let colorPixels = readRGBA(colorCG) else {
            return luminanceSource
        }

        let width = lumCG.width
        let height = lumCG.height
        let count = width * height
        var output = [UInt8](repeating: 0, count: count * 4)

        for i in 0..<count {
            let base = i * 4
            let lr = Float(lumPixels[base]) / 255.0
            let lg = Float(lumPixels[base + 1]) / 255.0
            let lb = Float(lumPixels[base + 2]) / 255.0
            let lumNew = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb

            let cr = Float(colorPixels[base]) / 255.0
            let cg = Float(colorPixels[base + 1]) / 255.0
            let cb = Float(colorPixels[base + 2]) / 255.0
            let lumOld = 0.2126 * cr + 0.7152 * cg + 0.0722 * cb

            if lumOld > 0.001 {
                let scale = lumNew / lumOld
                output[base] = clampNormalizedByte(cr * scale)
                output[base + 1] = clampNormalizedByte(cg * scale)
                output[base + 2] = clampNormalizedByte(cb * scale)
            } else {
                let mapped = clampNormalizedByte(lumNew)
                output[base] = mapped
                output[base + 1] = mapped
                output[base + 2] = mapped
            }
            output[base + 3] = colorPixels[base + 3]
        }

        guard let outCG = makeRGBA(
            output, width: width, height: height,
            colorSpace: colorCG.colorSpace
        ) else {
            return luminanceSource
        }
        return CIImage(cgImage: outCG)
    }

    // MARK: - Pixel Helpers

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
