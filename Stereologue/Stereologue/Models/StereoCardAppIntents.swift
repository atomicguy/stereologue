//
//  StereoCardAppIntents.swift
//  Stereologue
//
//  OS 26 - AppIntents Integration for Visual Intelligence & Spotlight
//

import Foundation
import AppIntents
import SwiftData
import CoreSpotlight
#if canImport(VisualIntelligence)
import VisualIntelligence
#endif

// MARK: - StereoCard App Entity

struct StereoCardEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Stereo Card",
        numericFormat: "\(placeholder: .int) stereo cards"
    )
    
    var id: String
    var title: String
    var author: String?
    var subject: String?
    var dateText: String?
    
    @Property(title: "Title")
    var displayTitle: String { title }
    
    @Property(title: "Author", indexingKey: \CSSearchableItemAttributeSet.authors)
    var displayAuthor: String? { author }
    
    @Property(title: "Subject", indexingKey: \CSSearchableItemAttributeSet.subject)
    var displaySubject: String? { subject }
    
    @Property(title: "Date")
    var displayDate: String? { dateText }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: [author, subject, dateText]
                .compactMap { $0 }
                .joined(separator: " • "),
            image: .init(systemName: "photo.on.rectangle")
        )
    }
    
    // For Spotlight indexing
    var searchableAttributes: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .image)
        
        attributes.title = title
        if let author = author {
            attributes.authors = [author]
        }
        if let subject = subject {
            attributes.subject = subject
        }
        if let dateText = dateText {
            attributes.contentDescription = "Date: \(dateText)"
        }
        
        attributes.keywords = [
            "stereo card",
            "stereoscope",
            "vintage",
            "historical"
        ]
        
        return attributes
    }
}

// MARK: - Open Card Intent

struct OpenStereoCardIntent: OpenIntent {
    static var title: LocalizedStringResource = "Open Stereo Card"
    
    @Parameter(title: "Stereo Card")
    var target: StereoCardEntity
    
    func perform() async throws -> some IntentResult {
        // Open the card in your app
        // You would implement deep linking here
        return .result()
    }
}

// MARK: - Visual Intelligence Integration

#if canImport(VisualIntelligence)
struct StereoCardVisualSearchQuery: IntentValueQuery {
    func values(for input: SemanticContentDescriptor) async throws -> [StereoCardEntity] {
        // Use labels from Visual Intelligence to find matching cards
        let labels = input.labels
        
        // You could also use the pixel buffer for image-based matching
        guard let pixelBuffer = input.pixelBuffer else {
            return []
        }
        
        // TODO: Implement your search logic here
        // This would query your SwiftData context for matching cards
        // For example, searching by subject matter, author, or visual similarity
        
        return []
    }
}
#endif

// MARK: - Collection App Entity

struct CollectionEntity: AppEntity, IndexedEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Collection",
        numericFormat: "\(placeholder: .int) collections"
    )
    
    var id: String
    var name: String
    var cardCount: Int
    
    @Property(title: "Name")
    var displayName: String { name }
    
    @Property(title: "Card Count")
    var displayCardCount: Int { cardCount }
    
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(cardCount) cards",
            image: .init(systemName: "rectangle.stack")
        )
    }
    
    var searchableAttributes: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = name
        attributes.contentDescription = "\(cardCount) stereo cards"
        attributes.keywords = ["collection", "stereo cards", "album"]
        return attributes
    }
}

// MARK: - App Shortcuts

struct StereologueShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SearchStereoCardsIntent(),
            phrases: [
                "Search my \(.applicationName) cards",
                "Find stereo cards in \(.applicationName)"
            ],
            shortTitle: "Search Cards",
            systemImageName: "magnifyingglass"
        )
    }
}

// MARK: - Search Intent

struct SearchStereoCardsIntent: AppIntent {
    static var title: LocalizedStringResource = "Search Stereo Cards"
    static var description = IntentDescription("Search your collection of stereo cards")
    
    @Parameter(title: "Search Term")
    var searchTerm: String?
    
    static var supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    
    func perform() async throws -> some IntentResult & ReturnsValue<[StereoCardEntity]> {
        // TODO: Implement search logic using SwiftData
        // Query your model context for matching cards
        
        let results: [StereoCardEntity] = []
        
        // If there are results and foreground is available, open the app
        if !results.isEmpty, systemContext.currentMode.canContinueInForeground {
            try? await continueInForeground(alwaysConfirm: false)
        }
        
        return .result(value: results)
    }
}

// MARK: - Spotlight Indexing Helper

@MainActor
class SpotlightIndexingService {
    private let modelContext: ModelContext
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func indexAllCards() async {
        do {
            // Fetch all cards from SwiftData
            let descriptor = FetchDescriptor<CardSchemaV1.StereoCard>()
            let cards = try modelContext.fetch(descriptor)
            
            // Convert to entities
            let entities = cards.map { card in
                StereoCardEntity(
                    id: card.uuid.uuidString,
                    title: card.titlePick?.text ?? "Untitled",
                    author: card.authors.first?.name,
                    subject: card.subjects.first?.name,
                    dateText: card.dates.first?.text
                )
            }
            
            // Index in Spotlight
            try await CSSearchableIndex.default().indexAppEntities(
                entities,
                priority: .normal
            )
            
            print("Successfully indexed \(entities.count) stereo cards in Spotlight")
        } catch {
            print("Failed to index cards in Spotlight: \(error)")
        }
    }
    
    func removeCardFromIndex(_ cardId: String) async {
        do {
            try await CSSearchableIndex.default().deleteAppEntities(
                identifiedBy: [cardId],
                ofType: StereoCardEntity.self
            )
        } catch {
            print("Failed to remove card from Spotlight: \(error)")
        }
    }
    
    func reindexCard(_ card: CardSchemaV1.StereoCard) async {
        let entity = StereoCardEntity(
            id: card.uuid.uuidString,
            title: card.titlePick?.text ?? "Untitled",
            author: card.authors.first?.name,
            subject: card.subjects.first?.name,
            dateText: card.dates.first?.text
        )
        
        do {
            try await CSSearchableIndex.default().indexAppEntities(
                [entity],
                priority: .normal
            )
        } catch {
            print("Failed to reindex card: \(error)")
        }
    }
}
