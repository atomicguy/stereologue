// SpatialPhotoService.swift
// visionOS spatial photo creation and optimization

import Foundation

#if os(visionOS)
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@globalActor
actor SpatialServiceActor {
    static let shared = SpatialServiceActor()
    private init() {}
}

@SpatialServiceActor
final class SpatialPhotoService {
    
    func createSpatialPhoto(
        frontData: Data?,
        backData: Data?,
        leftCrop: CropSchemaV1.Crop,
        rightCrop: CropSchemaV1.Crop
    ) async throws -> Data {
        guard let frontData = frontData else {
            throw SpatialServiceError.missingImageData
        }
        
        // Extract left and right images from front data using crops
        let leftImage = try await extractCroppedImage(from: frontData, crop: leftCrop)
        let rightImage = try await extractCroppedImage(from: frontData, crop: rightCrop)
        
        // Create spatial HEIF
        return try await generateSpatialHEIF(leftImage: leftImage, rightImage: rightImage)
    }
    
    func optimizeForSpatialViewing(_ spatialData: Data) async throws -> Data {
        // Optimize spatial photo for visionOS viewing
        return try await enhanceSpatialPhoto(spatialData)
    }
    
    func validateSpatialPhoto(_ data: Data) async throws -> Bool {
        // Validate that the data is a proper spatial photo
        return try await isSpatialPhoto(data)
    }
    
    private func extractCroppedImage(from imageData: Data, crop: CropSchemaV1.Crop) async throws -> CGImage {
        guard let image = createCGImage(from: imageData) else {
            throw SpatialServiceError.spatialConversionFailed
        }
        
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        
        let cropRect = CGRect(
            x: CGFloat(crop.x0) * imageWidth,
            y: CGFloat(crop.y0) * imageHeight,
            width: CGFloat(crop.x1 - crop.x0) * imageWidth,
            height: CGFloat(crop.y1 - crop.y0) * imageHeight
        )
        
        guard let croppedImage = image.cropping(to: cropRect) else {
            throw SpatialServiceError.spatialConversionFailed
        }
        
        return croppedImage
    }
    
    private func generateSpatialHEIF(leftImage: CGImage, rightImage: CGImage) async throws -> Data {
        // Create spatial HEIF format for visionOS
        let mutableData = NSMutableData()
        
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.heif.identifier as CFString,
            1,
            nil
        ) else {
            throw SpatialServiceError.spatialConversionFailed
        }
        
        // Configure spatial photo properties
        let properties: [String: Any] = [
            kCGImagePropertyHEIFDictionary as String: [
                "SpatialPhoto": true,
                "LeftEyeImage": leftImage,
                "RightEyeImage": rightImage
            ]
        ]
        
        // Add the main image (left eye) with spatial metadata
        CGImageDestinationAddImage(destination, leftImage, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw SpatialServiceError.spatialConversionFailed
        }
        
        return mutableData as Data
    }
    
    private func enhanceSpatialPhoto(_ data: Data) async throws -> Data {
        // Apply enhancements specific to spatial viewing
        // This could include depth optimization, color correction, etc.
        return data
    }
    
    private func isSpatialPhoto(_ data: Data) async throws -> Bool {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return false
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            return false
        }
        
        // Check for spatial photo metadata
        if let heifDict = properties[kCGImagePropertyHEIFDictionary as String] as? [String: Any] {
            return heifDict["SpatialPhoto"] as? Bool == true
        }
        
        return false
    }
    
    private func createCGImage(from data: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }
        return image
    }
}

// MARK: - Error Types
enum SpatialServiceError: LocalizedError {
    case missingImageData
    case spatialConversionFailed
    case invalidFormat
    case optimizationFailed
    
    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Missing required image data for spatial conversion"
        case .spatialConversionFailed:
            return "Failed to create spatial photo"
        case .invalidFormat:
            return "Invalid spatial photo format"
        case .optimizationFailed:
            return "Failed to optimize spatial photo"
        }
    }
}

#else

// Placeholder for non-visionOS platforms
@globalActor
actor SpatialServiceActor {
    static let shared = SpatialServiceActor()
    private init() {}
}

@SpatialServiceActor
final class SpatialPhotoService {
    func createSpatialPhoto(
        frontData: Data?,
        backData: Data?,
        leftCrop: Any,
        rightCrop: Any
    ) async throws -> Data {
        throw SpatialServiceError.unsupportedPlatform
    }
    
    func optimizeForSpatialViewing(_ spatialData: Data) async throws -> Data {
        throw SpatialServiceError.unsupportedPlatform
    }
}

enum SpatialServiceError: LocalizedError {
    case unsupportedPlatform
    
    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Spatial photos are only supported on visionOS"
        }
    }
}

#endif