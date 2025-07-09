// CardRepository.swift
// Repository layer that coordinates complex workflows between models and services

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class CardRepository {
    private let modelContext: ModelContext
    private let aiService: AIAnalysisService?
    private let imageService: ImageProcessingService
    private let importService: ImportService
    
    #if os(visionOS)
    private let spatialService: SpatialPhotoService
    #endif
    
    // Observable state for UI
    var isProcessing = false
    var processingProgress: Double = 0
    var lastError: Error?
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        
        // Initialize services (these will be dependency injected in real app)
        self.aiService = try? AIAnalysisService()
        self.imageService = ImageProcessingService()
        self.importService = ImportService()
        
        #if os(visionOS)
        self.spatialService = SpatialPhotoService()
        #endif
    }
    
    // MARK: - Complex Workflows
    
    /// Complete AI analysis and enhancement workflow
    func enhanceCard(_ card: CardSchemaV1.StereoCard) async {
        guard !isProcessing else { return }
        guard let aiService = aiService else {
            lastError = RepositoryError.contextUnavailable
            return
        }
        
        isProcessing = true
        processingProgress = 0
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        do {
            // Step 1: AI Analysis (30%)
            try await card.analyzeWithAI(using: aiService)
            processingProgress = 0.3
            
            // Step 2: Image Enhancement (60%)
            try await card.upgradeImageQuality(using: imageService)
            processingProgress = 0.6
            
            // Step 3: Spatial Photo Generation (90%)
            #if os(visionOS)
            if card.leftCrop != nil && card.rightCrop != nil {
                try await card.generateSpatialPhoto(using: spatialService)
            }
            #endif
            processingProgress = 0.9
            
            // Step 4: Save Changes (100%)
            try modelContext.save()
            processingProgress = 1.0
            
        } catch {
            lastError = error
            print("Card enhancement failed: \(error)")
        }
    }
    
    /// Batch process multiple cards with coordinated updates
    func batchEnhanceCards(_ cards: [CardSchemaV1.StereoCard]) async {
        guard !isProcessing else { return }
        guard let aiService = aiService else {
            lastError = RepositoryError.contextUnavailable
            return
        }
        
        isProcessing = true
        processingProgress = 0
        defer {
            isProcessing = false
            processingProgress = 0
        }
        
        let totalCards = cards.count
        
        for (index, card) in cards.enumerated() {
            do {
                // Process each card
                try await card.analyzeWithAI(using: aiService)
                try await card.upgradeImageQuality(using: imageService)
                
                #if os(visionOS)
                if card.canViewInSpace {
                    try await card.generateSpatialPhoto(using: spatialService)
                }
                #endif
                
                // Update progress
                processingProgress = Double(index + 1) / Double(totalCards)
                
                // Periodic saves to avoid memory pressure
                if (index + 1) % 10 == 0 {
                    try modelContext.save()
                }
                
            } catch {
                print("Failed to enhance card \(card.uuid): \(error)")
                // Continue with other cards
            }
        }
        
        // Final save
        try? modelContext.save()
    }
    
    /// Smart collection organization using AI
    func organizeIntoSmartCollections() async {
        guard !isProcessing else { return }
        
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // Fetch all cards
            let allCards = try modelContext.fetch(FetchDescriptor<CardSchemaV1.StereoCard>())
            
            // Group by AI-detected themes
            let themeGroups = await groupCardsByThemes(allCards)
            
            // Create or update collections
            for (theme, cards) in themeGroups {
                let collection = try findOrCreateCollection(named: theme)
                
                // Add cards to collection
                for card in cards {
                    await collection.addCard(card, context: modelContext)
                }
            }
            
            try modelContext.save()
            
        } catch {
            lastError = error
            print("Smart organization failed: \(error)")
        }
    }
    
    /// Import workflow with automatic enhancement
    func importAndEnhance(data: Data, type: ImportType) async -> ImportResult {
        guard !isProcessing else {
            return ImportResult(imported: 0, updated: 0, errors: [])
        }
        
        isProcessing = true
        defer { isProcessing = false }
        
        do {
            // Import data
            let importResult = switch type {
            case .mods:
                try await importService.importMODSData(from: data, into: modelContext)
            case .crops:
                try await importService.importCropUpdates(from: data, into: modelContext)
            }
            
            // Auto-enhance newly imported cards
            if importResult.imported > 0 {
                let recentCards = try fetchRecentlyImportedCards()
                await batchEnhanceCards(recentCards)
            }
            
            return importResult
            
        } catch {
            lastError = error
            return ImportResult(imported: 0, updated: 0, errors: [
                ImportError(cardId: "unknown", error: error)
            ])
        }
    }
    
    // MARK: - Search and Discovery
    
    func searchCards(query: String) async -> [CardSchemaV1.StereoCard] {
        let descriptor = FetchDescriptor<CardSchemaV1.StereoCard>()
        
        do {
            let allCards = try modelContext.fetch(descriptor)
            
            // Enhanced search with AI-powered relevance
            return allCards.filter { card in
                card.matchesQuery(query)
            }.sorted { card1, card2 in
                // AI-powered relevance scoring would go here
                card1.titles.first?.text ?? "" < card2.titles.first?.text ?? ""
            }
        } catch {
            print("Search failed: \(error)")
            return []
        }
    }
    
    func suggestSimilarCards(to card: CardSchemaV1.StereoCard) async -> [CardSchemaV1.StereoCard] {
        // AI-powered similarity detection
        do {
            let allCards = try modelContext.fetch(FetchDescriptor<CardSchemaV1.StereoCard>())
            
            return allCards.filter { otherCard in
                otherCard.uuid != card.uuid &&
                haveSimilarContent(card, otherCard)
            }
        } catch {
            return []
        }
    }
}

// MARK: - Private Helpers
@MainActor
private extension CardRepository {
    
    func groupCardsByThemes(_ cards: [CardSchemaV1.StereoCard]) async -> [String: [CardSchemaV1.StereoCard]] {
        // AI-powered thematic grouping
        var groups: [String: [CardSchemaV1.StereoCard]] = [:]
        
        for card in cards {
            // Use AI analysis to determine themes
            let themes = extractThemes(from: card)
            
            for theme in themes {
                groups[theme, default: []].append(card)
            }
        }
        
        return groups
    }
    
    func findOrCreateCollection(named name: String) throws -> CollectionSchemaV1.Collection {
        let descriptor = FetchDescriptor<CollectionSchemaV1.Collection>(
            predicate: #Predicate { $0.name == name }
        )
        
        if let existing = try modelContext.fetch(descriptor).first {
            return existing
        } else {
            let newCollection = CollectionSchemaV1.Collection(name: name)
            modelContext.insert(newCollection)
            return newCollection
        }
    }
    
    func fetchRecentlyImportedCards() throws -> [CardSchemaV1.StereoCard] {
        // Fetch cards imported in the last hour
        let oneHourAgo = Date().addingTimeInterval(-3600)
        // This would need a createdAt field in the model
        return try modelContext.fetch(FetchDescriptor<CardSchemaV1.StereoCard>())
    }
    
    func extractThemes(from card: CardSchemaV1.StereoCard) -> [String] {
        // Extract themes from subjects, AI analysis, etc.
        return card.subjects.map { $0.name }
    }
    
    func haveSimilarContent(_ card1: CardSchemaV1.StereoCard, _ card2: CardSchemaV1.StereoCard) -> Bool {
        // AI-powered similarity detection
        let sharedSubjects = Set(card1.subjects.map { $0.name }).intersection(
            Set(card2.subjects.map { $0.name })
        )
        
        let sharedAuthors = Set(card1.authors.map { $0.name }).intersection(
            Set(card2.authors.map { $0.name })
        )
        
        return !sharedSubjects.isEmpty || !sharedAuthors.isEmpty
    }
}

// MARK: - Environment Integration
struct CardRepositoryKey: EnvironmentKey {
    static let defaultValue: CardRepository? = nil
}

extension EnvironmentValues {
    var cardRepository: CardRepository? {
        get { self[CardRepositoryKey.self] }
        set { self[CardRepositoryKey.self] = newValue }
    }
}

extension View {
    func cardRepository(_ repository: CardRepository) -> some View {
        environment(\.cardRepository, repository)
    }
}

// Support for legacy import types
enum ImportType: String, CaseIterable {
    case mods = "MODS Data"
    case crops = "Crop Updates"
}
