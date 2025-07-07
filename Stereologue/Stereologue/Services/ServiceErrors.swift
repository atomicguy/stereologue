// ServiceErrors.swift
// Consolidated error types for all services

import Foundation

// MARK: - Service Error Protocol
protocol ServiceError: LocalizedError {
    var serviceName: String { get }
    var errorCode: String { get }
    var recoverySuggestion: String? { get }
}

// MARK: - AI Service Errors
enum AIServiceError: ServiceError {
    case invalidImageData
    case analysisTimeout
    case modelLoadFailed
    case insufficientData
    case processingInterrupted
    case rateLimitExceeded
    
    var serviceName: String { "AI Analysis Service" }
    
    var errorCode: String {
        switch self {
        case .invalidImageData: return "AI001"
        case .analysisTimeout: return "AI002"
        case .modelLoadFailed: return "AI003"
        case .insufficientData: return "AI004"
        case .processingInterrupted: return "AI005"
        case .rateLimitExceeded: return "AI006"
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Invalid image data provided"
        case .analysisTimeout:
            return "AI analysis timed out"
        case .modelLoadFailed:
            return "Failed to load AI model"
        case .insufficientData:
            return "Insufficient data for AI analysis"
        case .processingInterrupted:
            return "AI processing was interrupted"
        case .rateLimitExceeded:
            return "AI service rate limit exceeded"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .invalidImageData:
            return "Ensure the image data is in a supported format (JPEG, PNG, HEIF)"
        case .analysisTimeout:
            return "Try reducing image size or check network connection"
        case .modelLoadFailed:
            return "Restart the app or check available storage space"
        case .insufficientData:
            return "Provide higher quality images for better analysis"
        case .processingInterrupted:
            return "Retry the operation"
        case .rateLimitExceeded:
            return "Wait a moment before retrying the analysis"
        }
    }
}

// MARK: - Image Service Errors
enum ImageServiceError: ServiceError {
    case invalidImageData
    case conversionFailed
    case enhancementFailed
    case processingTimeout
    case unsupportedFormat
    case insufficientMemory
    case corruptedData
    
    var serviceName: String { "Image Processing Service" }
    
    var errorCode: String {
        switch self {
        case .invalidImageData: return "IMG001"
        case .conversionFailed: return "IMG002"
        case .enhancementFailed: return "IMG003"
        case .processingTimeout: return "IMG004"
        case .unsupportedFormat: return "IMG005"
        case .insufficientMemory: return "IMG006"
        case .corruptedData: return "IMG007"
        }
    }
    
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
        case .unsupportedFormat:
            return "Unsupported image format"
        case .insufficientMemory:
            return "Insufficient memory for image processing"
        case .corruptedData:
            return "Image data appears to be corrupted"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .invalidImageData, .corruptedData:
            return "Check the source image file and try again"
        case .conversionFailed, .enhancementFailed:
            return "Try with a different image or reduce image size"
        case .processingTimeout:
            return "Reduce image size or check system performance"
        case .unsupportedFormat:
            return "Convert image to JPEG, PNG, or HEIF format"
        case .insufficientMemory:
            return "Close other apps or restart the device"
        }
    }
}

// MARK: - Spatial Service Errors
enum SpatialServiceError: ServiceError {
    case missingImageData
    case spatialConversionFailed
    case invalidFormat
    case optimizationFailed
    case unsupportedPlatform
    case insufficientCropData
    case incompatibleStereoImages
    
    var serviceName: String { "Spatial Photo Service" }
    
    var errorCode: String {
        switch self {
        case .missingImageData: return "SPA001"
        case .spatialConversionFailed: return "SPA002"
        case .invalidFormat: return "SPA003"
        case .optimizationFailed: return "SPA004"
        case .unsupportedPlatform: return "SPA005"
        case .insufficientCropData: return "SPA006"
        case .incompatibleStereoImages: return "SPA007"
        }
    }
    
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
        case .unsupportedPlatform:
            return "Spatial photos are only supported on visionOS"
        case .insufficientCropData:
            return "Missing or invalid crop data for stereo pair"
        case .incompatibleStereoImages:
            return "Left and right images are incompatible for spatial viewing"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .missingImageData:
            return "Ensure both front and back images are available"
        case .spatialConversionFailed:
            return "Check image quality and crop data accuracy"
        case .invalidFormat:
            return "Use supported image formats (HEIF, JPEG)"
        case .optimizationFailed:
            return "Try with different optimization settings"
        case .unsupportedPlatform:
            return "Use visionOS to create and view spatial photos"
        case .insufficientCropData:
            return "Ensure crop coordinates are properly defined"
        case .incompatibleStereoImages:
            return "Verify that images form a proper stereo pair"
        }
    }
}

// MARK: - Import Service Errors
enum ImportServiceError: ServiceError {
    case cardNotFound(String)
    case invalidData
    case processingFailed(Error)
    case duplicateCard(String)
    case missingRequiredField(String)
    case networkError
    case storageError
    case parseError(String)
    
    var serviceName: String { "Import Service" }
    
    var errorCode: String {
        switch self {
        case .cardNotFound: return "IMP001"
        case .invalidData: return "IMP002"
        case .processingFailed: return "IMP003"
        case .duplicateCard: return "IMP004"
        case .missingRequiredField: return "IMP005"
        case .networkError: return "IMP006"
        case .storageError: return "IMP007"
        case .parseError: return "IMP008"
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .cardNotFound(let id):
            return "Card with ID \(id) not found"
        case .invalidData:
            return "Invalid import data format"
        case .processingFailed(let error):
            return "Processing failed: \(error.localizedDescription)"
        case .duplicateCard(let id):
            return "Duplicate card found: \(id)"
        case .missingRequiredField(let field):
            return "Missing required field: \(field)"
        case .networkError:
            return "Network connection error during import"
        case .storageError:
            return "Storage error while saving imported data"
        case .parseError(let details):
            return "Failed to parse import data: \(details)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .cardNotFound:
            return "Verify the card ID exists in the database"
        case .invalidData, .parseError:
            return "Check the import file format and structure"
        case .processingFailed:
            return "Review the data and try again"
        case .duplicateCard:
            return "Enable 'Skip Duplicates' option or update existing cards"
        case .missingRequiredField:
            return "Ensure all required fields are present in the import data"
        case .networkError:
            return "Check internet connection and retry"
        case .storageError:
            return "Check available storage space and try again"
        }
    }
}

// MARK: - Repository Errors
enum RepositoryError: ServiceError {
    case contextUnavailable
    case saveFailure(Error)
    case fetchFailure(Error)
    case relationshipError(String)
    case concurrencyConflict
    case dataCorruption
    
    var serviceName: String { "Card Repository" }
    
    var errorCode: String {
        switch self {
        case .contextUnavailable: return "REP001"
        case .saveFailure: return "REP002"
        case .fetchFailure: return "REP003"
        case .relationshipError: return "REP004"
        case .concurrencyConflict: return "REP005"
        case .dataCorruption: return "REP006"
        }
    }
    
    var errorDescription: String? {
        switch self {
        case .contextUnavailable:
            return "Model context is not available"
        case .saveFailure(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .fetchFailure(let error):
            return "Failed to fetch data: \(error.localizedDescription)"
        case .relationshipError(let details):
            return "Relationship error: \(details)"
        case .concurrencyConflict:
            return "Data was modified by another operation"
        case .dataCorruption:
            return "Data corruption detected"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .contextUnavailable:
            return "Restart the app to reinitialize the data context"
        case .saveFailure, .fetchFailure:
            return "Check available storage and try again"
        case .relationshipError:
            return "Verify data relationships and constraints"
        case .concurrencyConflict:
            return "Refresh data and retry the operation"
        case .dataCorruption:
            return "Consider restoring from backup or contact support"
        }
    }
}

// MARK: - Error Utilities
extension ServiceError {
    var fullDescription: String {
        var description = "[\(errorCode)] \(serviceName): \(errorDescription ?? "Unknown error")"
        
        if let recovery = recoverySuggestion {
            description += "\n\nSuggestion: \(recovery)"
        }
        
        return description
    }
}

// MARK: - Error Reporting
struct ErrorReport {
    let error: ServiceError
    let timestamp: Date
    let context: [String: Any]
    let userAction: String?
    
    init(error: ServiceError, context: [String: Any] = [:], userAction: String? = nil) {
        self.error = error
        self.timestamp = Date()
        self.context = context
        self.userAction = userAction
    }
    
    var summary: String {
        var summary = "Error: \(error.errorCode) at \(timestamp)"
        
        if let action = userAction {
            summary += " while \(action)"
        }
        
        return summary
    }
}