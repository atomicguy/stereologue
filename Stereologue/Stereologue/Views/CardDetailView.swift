//
//  CardDetailView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/8/25.
//

import SwiftUI
import SwiftData

// MARK: - Card Detail View

struct CardDetailView: View {
    let card: CardSchemaV1.StereoCard
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Large image display
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(cardColor)
                        .frame(height: 300)
                    
                    Image(systemName: "photo")
                        .font(.system(size: 60))
                        .foregroundStyle(.secondary)
                }
                
                // Metadata section
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.titlePick?.text ?? "Untitled Card")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if !card.authors.isEmpty {
                        MetadataRow(
                            label: "Authors",
                            value: card.authors.map(\.name).joined(separator: ", ")
                        )
                    }
                    
                    if !card.subjects.isEmpty {
                        MetadataRow(
                            label: "Subjects",
                            value: card.subjects.map(\.name).joined(separator: ", ")
                        )
                    }
                    
                    if !card.dates.isEmpty {
                        MetadataRow(
                            label: "Dates",
                            value: card.dates.map(\.text).joined(separator: ", ")
                        )
                    }
                    
                    MetadataRow(
                        label: "UUID",
                        value: card.uuid.uuidString
                    )
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                Spacer()
            }
            .padding()
        }
        .modifier(PlatformNavigationModifier())
    }
    
    private var cardColor: Color {
        if let hexColor = ColorUtils.color(from: card.cardColor) {
            return hexColor.opacity(card.colorOpacity)
        } else {
            return ColorUtils.defaultCardColor
        }
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            
            Text(value)
                .font(.body)
        }
    }
}

// MARK: - Placeholder View

struct CardPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Card",
            systemImage: "rectangle.stack",
            description: Text("Choose a stereoscopic card to view its details")
        )
    }
}

// MARK: - Navigation Views

struct AllCardsView: View {
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @State private var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        CardGridView(cards: allCards, selectedCard: $selectedCard)
            .navigationTitle("All Cards")
    }
}

struct CollectionDetailView: View {
    let collection: CollectionSchemaV1.Collection
    @State private var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        CardGridView(cards: collection.orderedCards, selectedCard: $selectedCard)
            .navigationTitle(collection.name)
    }
}
