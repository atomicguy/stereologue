// ImportService.swift
// Replaces: CropImportTypes.swift, ImportType.swift, JSONStructures.swift

import Foundation
import SwiftData

@globalActor
actor ImportServiceActor {
    static let shared = ImportServiceActor()
    private init() {}
}

@ImportServiceActor
final class ImportService {
    
    // MARK: - Import Operations
    func importMODSData(from data: Data, into context: ModelContext) async throws -> ImportResult {
        let decoder = JSONDecoder()
        let cardsData = try decoder.decode([StereoCardImportData].self, from: data)
        
        var imported = 0
        var updated = 0
        var errors: [ImportError] = []
        
        for cardData in cardsData {
            do {
                let result = try await processCardImport(cardData, context: context)
                switch result {
                case .imported: imported += 1
                case .updated: updated += 1
                }
            } catch {
                errors.append(ImportError(cardId: cardData.uuid, error: error))
            }
        }
        
        return ImportResult(imported: imported, updated: updated, errors: errors)
    }
    
    func importCropUpdates(from data: Data, into context: ModelContext) async throws -> ImportResult {
        let decoder = JSONDecoder()
        let cropUpdates = try decoder.decode([CropUpdateData].self, from: data)
        
        var updated = 0
        var errors: [ImportError] = []
        
        for cropUpdate in cropUpdates {
            do {
                try await processCropUpdate(cropUpdate, context: context)
                updated += 1
            } catch {
                errors.append(ImportError(cardId: cropUpdate.uuid, error: error))
            }
        }
        
        return ImportResult(imported: 0, updated: updated, errors: errors)
    }
}

// MARK: - Import Data Structures
struct StereoCardImportData: Codable {
    let uuid: String
    let titles: [String]
    let subjects: [String]
    let authors: [String]
    let dates: [String]
    let imageIds: ImageIdentifiers
    let leftCrop: CropData
    let rightCrop: CropData
    
    struct ImageIdentifiers: Codable {
        let front: String
        let back: String
    }
    
    struct CropData: Codable {
        let x0, y0, x1, y1, score: Float
        let side: String
    }
}

struct CropUpdateData: Codable {
    let uuid: String
    let left: CropData
    let right: CropData
    
    struct CropData: Codable {
        let x0, y0, x1, y1, score: Float
        let classification: String
        
        enum CodingKeys: String, CodingKey {
            case x0, y0, x1, y1, score
            case classification = "class"
        }
    }
}

// MARK: - Results
struct ImportResult {
    let imported: Int
    let updated: Int
    let errors: [ImportError]
    
    var isSuccess: Bool { errors.isEmpty }
    var totalProcessed: Int { imported + updated }
}

struct ImportError {
    let cardId: String
    let error: Error
}

enum ImportOperation {
    case imported
    case updated
}

// MARK: - Private Implementation
@ImportServiceActor
private extension ImportService {
    
    func processCardImport(_ data: StereoCardImportData, context: ModelContext) async throws -> ImportOperation {
        // Check if card exists
        let cardUUID = UUID(uuidString: data.uuid)!
        let existing = try context.fetch(
            FetchDescriptor<CardSchemaV1.StereoCard>(
                predicate: #Predicate { $0.uuid == cardUUID }
            )
        ).first
        
        if let existingCard = existing {
            // Update existing card
            try await updateCard(existingCard, with: data, context: context)
            return .updated
        } else {
            // Create new card
            try await createCard(from: data, context: context)
            return .imported
        }
    }
    
    func processCropUpdate(_ data: CropUpdateData, context: ModelContext) async throws {
        let cardUUID = UUID(uuidString: data.uuid)!
        
        guard let card = try context.fetch(
            FetchDescriptor<CardSchemaV1.StereoCard>(
                predicate: #Predicate { $0.uuid == cardUUID }
            )
        ).first else {
            throw ImportServiceError.cardNotFound(data.uuid)
        }
        
        // Update crops
        card.leftCrop = CropSchemaV1.Crop(
            x0: data.left.x0, y0: data.left.y0,
            x1: data.left.x1, y1: data.left.y1,
            score: data.left.score,
            side: CropSchemaV1.Side.left.rawValue
        )
        
        card.rightCrop = CropSchemaV1.Crop(
            x0: data.right.x0, y0: data.right.y0,
            x1: data.right.x1, y1: data.right.y1,
            score: data.right.score,
            side: CropSchemaV1.Side.right.rawValue
        )
        
        try context.save()
    }
    
    func createCard(from data: StereoCardImportData, context: ModelContext) async throws {
        // Implementation for creating new card from import data
        // This replaces the logic that was scattered in the import types
    }
    
    func updateCard(_ card: CardSchemaV1.StereoCard, with data: StereoCardImportData, context: ModelContext) async throws {
        // Implementation for updating existing card
    }
}
