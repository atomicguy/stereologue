//
//  FavoritesView.swift
//  Stereologue
//
//  Grid of cards the user has marked as favorites.
//  Bridges the user container (favorites) and catalog container (cards).
//

import SwiftUI
import SwiftData

struct FavoritesView: View {
    @Environment(\.modelContext) private var catalogContext
    @Environment(UserDataService.self) private var userDataService

    @State private var favoriteCards: [StereoCard] = []

    var body: some View {
        CardGridView(
            cards: favoriteCards,
            emptyTitle: "No Favorites",
            emptySystemImage: "heart",
            emptyDescription: "Cards you favorite will appear here."
        )
        .navigationTitle("Favorites")
        // Keyed on the reactive favorite list, so the grid refetches whenever
        // favorites change anywhere — fixing the stale-on-return `onAppear` bug.
        .task(id: userDataService.favoriteUUIDs) {
            favoriteCards = catalogContext.cards(matching: userDataService.favoriteUUIDs)
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        FavoritesView()
    }
    .previewEnvironment()
}
#endif
