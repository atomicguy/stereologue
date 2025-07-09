// ImportTypes.swift
// Data structures for importing card data and crop updates

import Foundation

// MARK: - Import Operations
enum ImportType: String, CaseIterable, Identifiable {
    case mods = "MODS Data"
    case crops = "Crop Updates"
    
    var id: String { rawValue }
    
    var description: String {
        switch self {
        case .mods:
            return "Import new cards from MODS library data"
        case .crops:
            return "Update existing cards with new crop information"
        }
    }
    
    var icon: String {
        switch self {
        case .mods:
            return "square.stack.3d.up.fill"
        case .crops:
            return "crop"
        }
    }
    
    var fileExtensions: [String] {
        switch self {
        case .mods:
            return ["json"]
        case .crops:
            return ["json"]
        }
    }
}

// MARK: - Import Results
struct ImportResult {
    let imported: Int
    let updated: Int
    let errors: [ImportError]
    
    var isSuccess: Bool { errors.isEmpty }
    var totalProcessed: Int { imported + updated }
    
    var summary: String {
        if isSuccess {
            return "Successfully processed \(totalProcessed) cards (\(imported) imported, \(updated) updated)"
        } else {
            return "Processed \(totalProcessed) cards with \(errors.count) errors"
        }
    }
}

struct ImportError {
    let cardId: String
    let error: Error
    let context: String?
    
    init(cardId: String, error: Error, context: String? = nil) {
        self.cardId = cardId
        self.error = error
        self.context = context
    }
    
    var description: String {
        let baseMessage = "Card \(cardId): \(error.localizedDescription)"
        if let context = context {
            return "\(baseMessage) (\(context))"
        }
        return baseMessage
    }
}

enum ImportOperation {
    case imported
    case updated
}

// MARK: - MODS Import Data
struct StereoCardImportData: Codable {
    let uuid: String
    let titles: [String]
    let subjects: [String]
    let authors: [String]
    let dates: [String]
    let imageIds: ImageIdentifiers
    let leftCrop: CropImportData
    let rightCrop: CropImportData
    
    enum CodingKeys: String, CodingKey {
        case uuid, titles, subjects, authors, dates
        case imageIds = "image_ids"
        case leftCrop = "left"
        case rightCrop = "right"
    }
}

struct ImageIdentifiers: Codable {
    let front: String
    let back: String
}

struct CropImportData: Codable {
    let x0, y0, x1, y1: Float
    let score: Float
    let side: String
}

// MARK: - Crop Update Data
struct CropUpdateData: Codable {
    let uuid: String
    let left: CropUpdateDetails
    let right: CropUpdateDetails
}

struct CropUpdateDetails: Codable {
    let x0, y0, x1, y1: Float
    let score: Float
    let classification: String
    
    enum CodingKeys: String, CodingKey {
        case x0, y0, x1, y1, score
        case classification = "class"
    }
    
    // Provide side string for model usage
    var side: String {
        classification
    }
}
