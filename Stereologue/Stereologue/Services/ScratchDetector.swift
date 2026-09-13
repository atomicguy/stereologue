//
//  ScratchDetector.swift
//  Stereologue
//
//  Debug-only wrapper around the Core ML scratch-detection U-Net converted
//  from Bringing Old Photos Back to Life (see tools/scratch-detector).
//
//  The 72 MB model is deliberately NOT bundled during the spike. Copy
//  `ScratchDetector512.mlpackage` (or a compiled `.mlmodelc`) into the app's
//  Documents folder — via Files on iPad/Vision Pro, or directly on macOS —
//  and the Restoration Eval tool picks it up.
//

#if DEBUG

import CoreML
import CoreGraphics
import CoreVideo
import Foundation
import OSLog

nonisolated final class ScratchDetector: @unchecked Sendable {

    private static let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "ScratchDetector")

    /// Where the tool looks for the model, in order.
    static var candidateURLs: [URL] {
        let docs = URL.documentsDirectory
        return [
            docs.appendingPathComponent("ScratchDetector512.mlmodelc"),
            docs.appendingPathComponent("ScratchDetector512.mlpackage"),
            docs.appendingPathComponent("ScratchDetector256.mlmodelc"),
            docs.appendingPathComponent("ScratchDetector256.mlpackage"),
        ]
    }

    /// Human-readable install hint for the eval tool.
    static var installHint: String {
        "Copy ScratchDetector512.mlpackage into \(URL.documentsDirectory.path)"
    }

    private let model: MLModel
    /// The model's fixed square input size (256 or 512).
    let inputSize: Int

    /// Loads the first model found in `candidateURLs`, compiling a `.mlpackage`
    /// on the fly. Slow the first time (seconds); call off the main actor.
    static func load() throws -> ScratchDetector {
        guard let url = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: installHint])
        }
        let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: compiled, configuration: config)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "model has no 'image' input"])
        }
        logger.info("Loaded scratch detector from \(url.lastPathComponent) (\(constraint.pixelsWide)px)")
        return ScratchDetector(model: model, inputSize: constraint.pixelsWide)
    }

    private init(model: MLModel, inputSize: Int) {
        self.model = model
        self.inputSize = inputSize
    }

    // MARK: - Inference

    /// Scratch probability (0…1 as bytes 0…255) at the image's own size.
    /// The image is converted to grayscale, resized to the model's square
    /// input, run, and the map resized back with nearest-neighbour sampling.
    func probabilityMap(for image: CGImage) -> [UInt8]? {
        guard let input = grayscaleBuffer(image, size: inputSize) else { return nil }
        let prediction: MLFeatureProvider
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)])
            prediction = try model.prediction(from: provider)
        } catch {
            Self.logger.error("Scratch detector prediction failed: \(error.localizedDescription)")
            return nil
        }
        guard let out = prediction.featureValue(for: "probability")?.imageBufferValue,
              CVPixelBufferGetPixelFormatType(out) == kCVPixelFormatType_OneComponent8 else { return nil }

        CVPixelBufferLockBaseAddress(out, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(out, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(out) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(out)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let n = inputSize

        // Nearest-neighbour upsample to the source size.
        let width = image.width, height = image.height
        var map = [UInt8](repeating: 0, count: width * height)
        map.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                let sy = min(n - 1, y * n / height)
                for x in 0..<width {
                    let sx = min(n - 1, x * n / width)
                    dst[y * width + x] = src[sy * rowBytes + sx]
                }
            }
        }
        return map
    }

    /// The image with pixels whose probability is at or above `threshold`
    /// painted red, for visual inspection. The original thresholds at 0.4.
    func overlay(on image: CGImage, threshold: Float = 0.4) -> CGImage? {
        guard let map = probabilityMap(for: image), let pixels = Self.rgba(image) else { return nil }
        var out = pixels
        let cut = UInt8(max(0, min(255, threshold * 255)))
        out.withUnsafeMutableBufferPointer { px in
            for i in 0..<map.count where map[i] >= cut {
                let b = i * 4
                px[b] = UInt8(Int(px[b]) * 3 / 10 + 178)
                px[b + 1] = UInt8(Int(px[b + 1]) * 3 / 10)
                px[b + 2] = UInt8(Int(px[b + 2]) * 3 / 10)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(
            width: image.width, height: image.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// Fraction of pixels at or above `threshold`, whole image and with a
    /// border margin excluded (print edges are a known false-positive source).
    func maskFractions(for image: CGImage, threshold: Float = 0.4, margin: Double = 0.06) -> (whole: Double, interior: Double)? {
        guard let map = probabilityMap(for: image) else { return nil }
        let cut = UInt8(max(0, min(255, threshold * 255)))
        let width = image.width, height = image.height
        let mx = Int(Double(width) * margin), my = Int(Double(height) * margin)
        var whole = 0, interior = 0, interiorCount = 0
        for y in 0..<height {
            for x in 0..<width {
                let hit = map[y * width + x] >= cut
                if hit { whole += 1 }
                if x >= mx, x < width - mx, y >= my, y < height - my {
                    interiorCount += 1
                    if hit { interior += 1 }
                }
            }
        }
        return (Double(whole) / Double(width * height), interiorCount > 0 ? Double(interior) / Double(interiorCount) : 0)
    }

    // MARK: - Pixel helpers

    private func grayscaleBuffer(_ image: CGImage, size: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true]
        guard CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_OneComponent8, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(
                data: base, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return buffer
    }

    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }
}

#endif
