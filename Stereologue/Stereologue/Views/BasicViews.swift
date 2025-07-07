//
//  BasicViews.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

// MARK: - Detail View
struct CardDetailView: View {
    let card: CardSchemaV1.StereoCard
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Large image display
                CardImageView(card: card)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                
                // Metadata
                VStack(alignment: .leading, spacing: 12) {
                    Text(card.titlePick?.text ?? "Untitled Card")
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if !card.authors.isEmpty {
                        LabeledContent("Authors") {
                            Text(card.authors.map(\.name).joined(separator: ", "))
                        }
                    }
                    
                    if !card.subjects.isEmpty {
                        LabeledContent("Subjects") {
                            Text(card.subjects.map(\.name).joined(separator: ", "))
                        }
                    }
                    
                    if !card.dates.isEmpty {
                        LabeledContent("Dates") {
                            Text(card.dates.map(\.text).joined(separator: ", "))
                        }
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                
                Spacer()
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: card.uuid.uuidString) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
    }
}

// MARK: - Placeholder Views
struct CardPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "Select a Card",
            systemImage: "rectangle.stack",
            description: Text("Choose a stereoscopic card to view its details")
        )
    }
}

struct AllCardsView: View {
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @State private var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        CardGridView(cards: allCards, selectedCard: $selectedCard)
            .navigationTitle("All Cards")
    }
}

struct RecentCardsView: View {
    @Query(sort: \CardSchemaV1.StereoCard.uuid) private var recentCards: [CardSchemaV1.StereoCard]
    @State private var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        CardGridView(cards: Array(recentCards.prefix(50)), selectedCard: $selectedCard)
            .navigationTitle("Recent Cards")
    }
}

struct FavoritesView: View {
    var body: some View {
        ContentUnavailableView(
            "No Favorites",
            systemImage: "heart",
            description: Text("Favorite cards will appear here")
        )
        .navigationTitle("Favorites")
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

struct SmartCollectionView: View {
    let filter: SmartFilter
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @State private var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        CardGridView(cards: filteredCards, selectedCard: $selectedCard)
            .navigationTitle(filter.title)
    }
    
    private var filteredCards: [CardSchemaV1.StereoCard] {
        switch filter {
        case .needsProcessing:
            return allCards.filter { $0.needsImageUpgrade }
        case .highQuality:
            return allCards.filter { $0.hasHighQualityImages }
        case .spatialReady:
            return allCards.filter { $0.canViewInSpace }
        }
    }
}

enum SmartFilter {
    case needsProcessing, highQuality, spatialReady
    
    var title: String {
        switch self {
        case .needsProcessing: return "Needs Processing"
        case .highQuality: return "High Quality"
        case .spatialReady: return "Spatial Ready"
        }
    }
}

// MARK: - Supporting Views
struct CardImageView: View {
    let card: CardSchemaV1.StereoCard
    @State private var image: Image?
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(card.adaptiveColor)
            
            if let image = image {
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView()
            }
        }
        .task {
            await loadImage()
        }
    }
    
    private func loadImage() async {
        guard let imageData = card.frontStandardData ?? card.frontThumbnailData,
              let uiImage = UIImage(data: imageData) else {
            return
        }
        
        image = Image(uiImage: uiImage)
    }
}

struct CollectionThumbnailView: View {
    let collection: CollectionSchemaV1.Collection
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
            
            if let firstCard = collection.orderedCards.first,
               let thumbnailData = firstCard.frontThumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Import View
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cardRepository) private var repository
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                ContentUnavailableView(
                    "Import Cards",
                    systemImage: "square.and.arrow.down",
                    description: Text("Import functionality coming soon")
                )
            }
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Platform-specific Views
#if os(macOS)
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            AISettingsView()
                .tabItem {
                    Label("AI & Analysis", systemImage: "sparkles")
                }
        }
        .frame(width: 500, height: 400)
    }
}

struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Text("General settings coming soon")
        }
        .padding()
    }
}

struct AISettingsView: View {
    var body: some View {
        Form {
            Text("AI settings coming soon")
        }
        .padding()
    }
}
#endif

#if os(visionOS)
struct SpatialControlsView: View {
    @Binding var selectedCard: CardSchemaV1.StereoCard?
    
    var body: some View {
        HStack {
            Button("View in Space", systemImage: "visionpro") {
                // Handle spatial viewing
            }
            .disabled(selectedCard?.canViewInSpace != true)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SpatialCardEnvironment: View {
    var body: some View {
        Text("Spatial card viewing coming soon")
            .font(.title)
            .padding()
    }
}
#endif