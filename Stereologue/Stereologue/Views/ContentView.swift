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
    
    var body: some View {
        NavigationSplitView {
            SidebarView(
                collections: collections,
                searchText: $searchText
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
    }
    
    private var filteredCards: [CardSchemaV1.StereoCard] {
        if searchText.isEmpty {
            return allCards
        } else {
            return allCards.filter { card in
                let title = card.titlePick?.text ?? ""
                return title.localizedCaseInsensitiveContains(searchText)
            }
        }
    }
}
