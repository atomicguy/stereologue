//
//  ContentView.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.cardRepository) private var repository
    @Query private var allCards: [CardSchemaV1.StereoCard]
    @Query private var collections: [CollectionSchemaV1.Collection]
    
    @State private var selectedCard: CardSchemaV1.StereoCard?
    @State private var searchText = ""
    @State private var showingImport = false
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                collections: collections,
                searchText: $searchText,
                showingImport: $showingImport
            )
        } content: {
            CardGridView(
                cards: filteredCards,
                selectedCard: $selectedCard
            )
        } detail: {
            if let selectedCard = selectedCard {
                CardDetailView(card: selectedCard)
            } else {
                CardPlaceholderView()
            }
        }
        .searchable(text: $searchText)
        .sheet(isPresented: $showingImport) {
            ImportView()
        }
        #if os(visionOS)
        .ornament(attachmentAnchor: .scene(.bottom)) {
            SpatialControlsView(selectedCard: $selectedCard)
        }
        #endif
    }
    
    private var filteredCards: [CardSchemaV1.StereoCard] {
        if searchText.isEmpty {
            return allCards
        } else {
            return allCards.filter { $0.matchesQuery(searchText) }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: CardSchemaV1.StereoCard.self, inMemory: true)
}