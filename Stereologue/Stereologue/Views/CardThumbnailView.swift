//
//  CardThumbnailView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

struct CardThumbnailView: View {
    let card: CardSchemaV1.StereoCard
    
    @State private var thumbnailImage: Image?
    @State private var isLoading = true
    
    var body: some View {
        VStack(spacing: 8) {
            // Card Image
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(card.adaptiveColor)
                    .overlay {
                        if let thumbnailImage = thumbnailImage {
                            thumbnailImage
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipped()
                        } else {
                            ProgressView()
                                .opacity(isLoading ? 1 : 0)
                        }
                    }
                    .overlay {
                        // Glass morphism overlay
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.white.opacity(0.3), lineWidth: 0.5)
                    }
                
                // Status indicators
                VStack {
                    HStack {
                        Spacer()
                        
                        if card.canViewInSpace {
                            Image(systemName: "view.3d")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    
                    Spacer()
                    
                    HStack {
                        if card.needsImageUpgrade {
                            Image(systemName: "arrow.up.circle")
                                .font(.caption)
                                .foregroundStyle(.yellow)
                                .padding(4)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        
                        Spacer()
                        
                        if !card.subjects.isEmpty {
                            Text("\(card.subjects.count)")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .padding(2)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
                .padding(8)
            }
            .aspectRatio(3/2, contentMode: .fit)
            
            // Card metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(card.titlePick?.text ?? "Untitled")
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                if let author = card.authors.first?.name {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                if let date = card.dates.first?.text {
                    Text(date)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await loadThumbnail()
        }
    }
    
    private func loadThumbnail() async {
        defer { isLoading = false }
        
        guard let thumbnailData = card.frontThumbnailData,
              let uiImage = UIImage(data: thumbnailData) else {
            return
        }
        
        thumbnailImage = Image(uiImage: uiImage)
    }
}

struct CardContextMenu: View {
    let card: CardSchemaV1.StereoCard
    @Environment(\.cardRepository) private var repository
    
    var body: some View {
        Section {
            Button("View Details", systemImage: "info.circle") {
                // Handle view details
            }
            
            Button("Edit", systemImage: "pencil") {
                // Handle edit
            }
        }
        
        Section {
            Button("Enhance with AI", systemImage: "sparkles") {
                Task {
                    await repository?.enhanceCard(card)
                }
            }
            
            if card.needsImageUpgrade {
                Button("Upgrade Quality", systemImage: "arrow.up.circle") {
                    // Handle quality upgrade
                }
            }
            
            #if os(visionOS)
            if card.canViewInSpace {
                Button("View in Space", systemImage: "visionpro") {
                    // Handle spatial viewing
                }
            }
            #endif
        }
        
        Section {
            Button("Share", systemImage: "square.and.arrow.up") {
                // Handle share
            }
            
            Button("Delete", systemImage: "trash", role: .destructive) {
                // Handle delete
            }
        }
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: CardSchemaV1.StereoCard.self, configurations: config)
    
    let card = CardSchemaV1.StereoCard(
        uuid: UUID(),
        colorOpacity: 0.15
    )
    
    return CardThumbnailView(card: card)
        .frame(width: 200, height: 280)
        .padding()
        .modelContainer(container)
}