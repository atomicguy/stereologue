//
//  SidebarView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

struct SidebarView: View {
    let collections: [CollectionSchemaV1.Collection]
    @Binding var searchText: String
    @Binding var showingImport: Bool
    
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @Environment(\.cardRepository) private var repository
    
    var body: some View {
        List {
            Section("Library") {
                NavigationLink {
                    AllCardsView()
                } label: {
                    Label("All Cards", systemImage: "rectangle.stack")
                    Spacer()
                    Text("\(allCards.count)")
                        .foregroundStyle(.secondary)
                }
                
                NavigationLink {
                    RecentCardsView()
                } label: {
                    Label("Recent", systemImage: "clock")
                }
                
                NavigationLink {
                    FavoritesView()
                } label: {
                    Label("Favorites", systemImage: "heart")
                }
            }
            
            Section("Collections") {
                ForEach(collections) { collection in
                    NavigationLink {
                        CollectionDetailView(collection: collection)
                    } label: {
                        CollectionRowView(collection: collection)
                    }
                }
            }
            
            Section("Smart Collections") {
                NavigationLink {
                    SmartCollectionView(filter: .needsProcessing)
                } label: {
                    Label("Needs Processing", systemImage: "gearshape")
                }
                
                NavigationLink {
                    SmartCollectionView(filter: .highQuality)
                } label: {
                    Label("High Quality", systemImage: "sparkles")
                }
                
                #if os(visionOS)
                NavigationLink {
                    SmartCollectionView(filter: .spatialReady)
                } label: {
                    Label("Spatial Ready", systemImage: "view.3d")
                }
                #endif
            }
        }
        .navigationTitle("Stereologue")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Import", systemImage: "square.and.arrow.down") {
                    showingImport = true
                }
            }
            
            #if os(visionOS)
            ToolbarItem(placement: .secondaryAction) {
                Button("View in Space", systemImage: "visionpro") {
                    Task {
                        await openSpatialExperience()
                    }
                }
            }
            #endif
        }
    }
    
    #if os(visionOS)
    private func openSpatialExperience() async {
        // Open immersive space
    }
    #endif
}

struct CollectionRowView: View {
    let collection: CollectionSchemaV1.Collection
    
    var body: some View {
        HStack {
            CollectionThumbnailView(collection: collection)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name)
                    .font(.body)
                
                Text("\(collection.cards.count) cards")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
        }
    }
}

#Preview {
    NavigationSplitView {
        SidebarView(
            collections: [],
            searchText: .constant(""),
            showingImport: .constant(false)
        )
    } detail: {
        Text("Detail")
    }
    .modelContainer(for: CardSchemaV1.StereoCard.self, inMemory: true)
}