//
//  Collection.swift
//  Retroview
//
//  Created by Adam Schuster on 11/27/24.
//

import Foundation
import OSLog
import SwiftData

private let logger = Logger(
    subsystem: "com.example.retroview", category: "CollectionModel")

enum CollectionSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Collection.self]
    }

    @Model
    class Collection {
        @Attribute(.unique) var id: UUID
        var name: String
        var createdAt: Date
        var updatedAt: Date

        var cardOrder: [UUID] = []

        @Relationship(
            deleteRule: .nullify, inverse: \CardSchemaV1.StereoCard.collections)
        var cards: [CardSchemaV1.StereoCard] = []
        
        @Attribute(.externalStorage) var collectionThumbnail: Data?

        // Computed property to get cards in order
        var orderedCards: [CardSchemaV1.StereoCard] {
            cardOrder.compactMap { orderId in
                cards.first { $0.uuid == orderId }
            }
        }
        init(name: String) {
            self.id = UUID()
            self.name = name
            self.createdAt = Date()
            self.updatedAt = Date()
        }

        @MainActor
        func addCard(_ card: CardSchemaV1.StereoCard, context: ModelContext) {
            // Quick check if card already exists
            let cardId = card.uuid
            guard !cardOrder.contains(cardId) else { return }

            // Update relationships
            cards.append(card)
            cardOrder.append(cardId)
            updatedAt = Date()

            // Save in background
            Task.detached(priority: .utility) {
                // Ensure we're on the main actor for the save
                await MainActor.run {
                    try? context.save()
                }
            }
        }

        @MainActor
        func removeCard(_ card: CardSchemaV1.StereoCard, context: ModelContext)
        {
            let cardId = card.uuid

            // Update relationships
            cards.removeAll { $0.uuid == cardId }
            cardOrder.removeAll { $0 == cardId }
            updatedAt = Date()

            // Save in background
            Task.detached(priority: .utility) {
                await MainActor.run {
                    try? context.save()
                }
            }
        }

        func hasCard(_ card: CardSchemaV1.StereoCard) -> Bool {
            // Use cardOrder for faster lookup instead of searching relationships
            cardOrder.contains(card.uuid)
        }
    }
}

extension CollectionSchemaV1.Collection: Identifiable {}
