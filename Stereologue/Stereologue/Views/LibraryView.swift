//
//  LibraryView.swift
//  Stereologue
//
//  Grid of all stereoview cards in the catalog.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @Query private var cards: [StereoCard]
    @State private var searchText = ""

    private var displayedCards: [StereoCard] {
        if searchText.isEmpty {
            return cards
        }
        return cards.filter { $0.title.localizedStandardContains(searchText) }
    }

    var body: some View {
        CardGridView(
            cards: displayedCards,
            emptyTitle: searchText.isEmpty ? "No Cards" : "No Results",
            emptySystemImage: searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
            emptyDescription: searchText.isEmpty
                ? "The catalog could not be loaded."
                : "No cards match \"\(searchText)\"."
        )
        .navigationTitle("Stereologue")
        .searchable(text: $searchText, prompt: "Cards, subjects, creators…")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        LibraryView()
    }
    .previewEnvironment()
}
#endif
