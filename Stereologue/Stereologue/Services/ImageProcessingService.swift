// ImageProcessingService.swift
// Image enhancement and processing service

import Foundation
import CoreImage
import CoreGraphics

@globalActor
actor ImageServiceActor {
    static let shared = ImageServiceActor()
    private init() {}
}

@ImageServiceActor
final class ImageProcessingService {
    private let ciContext: CIContext
    
    init() {
        self.ciContext = CIContext()
    }
    
    func enhanceImage(_ imageData: Data) async throws -> Data {
        // AI-powered image enhancement
        let image = try createCGImage(from: imageData)
        let enhanced = try await performEnhancement(image)
        return try convertToData(enhanced)
    }
    
    func generateThumbnail(_ imageData: Data, size: CGSize) async throws -> Data {
        let image = try createCGImage(from: imageData)
        let thumbnail = try await createThumbnail(image, targetSize: size)
        return try convertToData(thumbnail)
    }
    
    func extractCrops(from imageData: Data) async throws -> (left: CropData, right: CropData) {
        // AI-powered stereo pair detection
        let image = try createCGImage(from: imageData)
        return try await detectStereoPairs(in: image)
    }
    
    func optimizeForDisplay(_ imageData: Data, targetSize: CGSize) async throws -> Data {
        let image = try createCGImage(from: imageData)
        let optimized = try await optimizeImage(image, for: targetSize)
        return try convertToData(optimized)
    }
    
    private func createCGImage(from data: Data) throws -> CGImage {
        #if os(macOS)
        guard let image = NSImage(data: data)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageServiceError.invalidImageData
        }
        #else
        guard let image = UIImage(data: data)?.cgImage else {
            throw ImageServiceError.invalidImageData
        }
        #endif
        return image
    }
    
    private func performEnhancement(_ image: CGImage) async throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        
        // Apply enhancement filters
        guard let filter = CIFilter(name: "CIUnsharpMask") else {
            return image
        }
        
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(0.5, forKey: kCIInputIntensityKey)
        filter.setValue(2.5, forKey: kCIInputRadiusKey)
        
        guard let outputImage = filter.outputImage,
              let enhanced = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return image
        }
        
        return enhanced
    }
    
    private func createThumbnail(_ image: CGImage, targetSize: CGSize) async throws -> CGImage {
        let imageSize = CGSize(width: image.width, height: image.height)
        let scale = min(targetSize.width / imageSize.width, targetSize.height / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        
        #if os(macOS)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(scaledSize.width),
            height: Int(scaledSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ImageServiceError.conversionFailed
        }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: scaledSize))
        
        guard let thumbnail = context.makeImage() else {
            throw ImageServiceError.conversionFailed
        }
        
        return thumbnail
        #else
        UIGraphicsBeginImageContextWithOptions(scaledSize, false, 0.0)
        let uiImage = UIImage(cgImage: image)
        uiImage.draw(in: CGRect(origin: .zero, size: scaledSize))
        let thumbnail = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        guard let thumbnailCG = thumbnail?.cgImage else {
            throw ImageServiceError.conversionFailed
        }
        
        return thumbnailCG
        #endif
    }
    
    private func detectStereoPairs(in image: CGImage) async throws -> (left: CropData, right: CropData) {
        // Implement stereo pair detection algorithm
        // This would use computer vision to detect the left/right images in a stereocard
        return (
            left: CropData(x0: 0, y0: 0, x1: 0.5, y1: 1, score: 0.9),
            right: CropData(x0: 0.5, y0: 0, x1: 1, y1: 1, score: 0.9)
        )
    }
    
    private func optimizeImage(_ image: CGImage, for targetSize: CGSize) async throws -> CGImage {
        // Optimize image for specific display requirements
        return try await createThumbnail(image, targetSize: targetSize)
    }
    
    private func convertToData(_ image: CGImage) throws -> Data {
        #if os(macOS)
        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let data = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw ImageServiceError.conversionFailed
        }
        return data
        #else
        let uiImage = UIImage(cgImage: image)
        guard let data = uiImage.jpegData(compressionQuality: 0.8) else {
            throw ImageServiceError.conversionFailed
        }
        return data
        #endif
    }
}

// MARK: - Supporting Types
struct CropData {
    let x0, y0, x1, y1: Float
    let score: Float
}

// MARK: - Error Types
enum ImageServiceError: LocalizedError {
    case invalidImageData
    case conversionFailed
    case enhancementFailed
    case processingTimeout
    
    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Invalid image data"
        case .conversionFailed:
            return "Failed to convert image"
        case .enhancementFailed:
            return "Image enhancement failed"
        case .processingTimeout:
            return "Image processing timed out"
        }
    }
}