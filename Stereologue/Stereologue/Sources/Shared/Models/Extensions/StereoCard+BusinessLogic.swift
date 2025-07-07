// StereoCard+BusinessLogic.swift
// Enhanced Active Record pattern with business logic

import Foundation
import SwiftData
import SwiftUI

extension CardSchemaV1.StereoCard {
    
    // MARK: - AI Analysis
    @MainActor
    func analyzeWithAI(using aiService: AIAnalysisService) async throws {
        guard let imageData = frontStandardData else { 
            throw CardError.missingImageData 
        }
        
        let analysis = try await aiService.analyzeCard(imageData: imageData)
        
        // Update subjects based on AI analysis
        await updateSubjects(from: analysis.subjects)
        
        // Update metadata
        await updateMetadata(from: analysis)
    }
    
    // MARK: - Smart Organization
    func suggestedCollections(in context: ModelContext) throws -> [CollectionSchemaV1.Collection] {
        let descriptor = FetchDescriptor<CollectionSchemaV1.Collection>()
        let allCollections = try context.fetch(descriptor)
        
        return allCollections.filter { collection in
            hasRelatedContent(to: collection)
        }
    }
    
    // MARK: - Image Quality Management
    var hasHighQualityImages: Bool {
        frontStandardData != nil && backStandardData != nil
    }
    
    var needsImageUpgrade: Bool {
        frontThumbnailData != nil && frontStandardData == nil
    }
    
    @MainActor
    func upgradeImageQuality(using imageService: ImageProcessingService) async throws {
        guard needsImageUpgrade else { return }
        
        if let frontThumb = frontThumbnailData {
            let enhanced = try await imageService.enhanceImage(frontThumb)
            frontStandardData = enhanced
        }
        
        if let backThumb = backThumbnailData {
            let enhanced = try await imageService.enhanceImage(backThumb)
            backStandardData = enhanced
        }
    }
    
    // MARK: - Spatial Features
    var canViewInSpace: Bool {
        #if os(visionOS)
        return spatialPhotoData != nil || (leftCrop != nil && rightCrop != nil)
        #else
        return false
        #endif
    }
    
    @MainActor
    func generateSpatialPhoto(using spatialService: SpatialPhotoService) async throws {
        #if os(visionOS)
        guard leftCrop != nil, rightCrop != nil else {
            throw CardError.insufficientCropData
        }
        
        let spatialData = try await spatialService.createSpatialPhoto(
            frontData: frontStandardData,
            backData: backStandardData,
            leftCrop: leftCrop!,
            rightCrop: rightCrop!
        )
        
        spatialPhotoData = spatialData
        #endif
    }
    
    // MARK: - Smart Search
    func matchesQuery(_ query: String) -> Bool {
        let lowercaseQuery = query.lowercased()
        
        // Search titles
        if titles.contains(where: { $0.text.lowercased().contains(lowercaseQuery) }) {
            return true
        }
        
        // Search authors
        if authors.contains(where: { $0.name.lowercased().contains(lowercaseQuery) }) {
            return true
        }
        
        // Search subjects
        if subjects.contains(where: { $0.name.lowercased().contains(lowercaseQuery) }) {
            return true
        }
        
        return false
    }
    
    // MARK: - Liquid Glass Design Support
    var adaptiveColor: Color {
        Color(hex: cardColor)?.adaptiveVariant ?? Color.cardDefault
    }
    
    var glassMorphismOpacity: Double {
        min(max(colorOpacity * 1.2, 0.1), 0.3)
    }
}

// MARK: - Helper Methods
private extension CardSchemaV1.StereoCard {
    
    @MainActor
    func updateSubjects(from aiSubjects: [String]) async {
        let context = modelContext!
        
        for subjectName in aiSubjects {
            let existingSubject = try? context.fetch(
                FetchDescriptor<SubjectSchemaV1.Subject>(
                    predicate: #Predicate { $0.name == subjectName }
                )
            ).first
            
            let subject = existingSubject ?? SubjectSchemaV1.Subject(name: subjectName)
            
            if !subjects.contains(where: { $0.name == subjectName }) {
                subjects.append(subject)
                subject.cards.append(self)
            }
        }
    }
    
    @MainActor
    func updateMetadata(from analysis: AIAnalysis) async {
        // Update based on AI analysis results
    }
    
    func hasRelatedContent(to collection: CollectionSchemaV1.Collection) -> Bool {
        // Smart logic to determine if card belongs in collection
        return false // Placeholder
    }
}

// MARK: - Error Types
enum CardError: LocalizedError {
    case missingImageData
    case insufficientCropData
    case processingFailed
    
    var errorDescription: String? {
        switch self {
        case .missingImageData:
            return "Card is missing required image data"
        case .insufficientCropData:
            return "Card needs crop data for spatial viewing"
        case .processingFailed:
            return "Failed to process card data"
        }
    }
}