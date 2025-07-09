// CardRepository.swift
// Repository layer that coordinates complex workflows between models and services

import Foundation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class CardRepository {
    private let modelContext: ModelContext
    
    // Observable state for UI
    var isProcessing = false
    var lastError: Error?
    
    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    // MARK: - Basic Operations
    
    func save() throws {
        try modelContext.save()
    }
    
    func delete(_ card: CardSchemaV1.StereoCard) throws {
        modelContext.delete(card)
        try save()
    }
    
    func createSampleCard() throws -> CardSchemaV1.StereoCard {
        let card = CardSchemaV1.StereoCard(
            uuid: UUID(),
            colorOpacity: 0.15
        )
        
        // Add sample title
        let title = TitleSchemaV1.Title(text: "Sample Stereocard")
        card.titles.append(title)
        card.titlePick = title
        
        modelContext.insert(card)
        try save()
        
        return card
    }
}

// MARK: - Environment Setup

struct CardRepositoryKey: EnvironmentKey {
    static let defaultValue: CardRepository? = nil
}

extension EnvironmentValues {
    var cardRepository: CardRepository? {
        get { self[CardRepositoryKey.self] }
        set { self[CardRepositoryKey.self] = newValue }
    }
}
