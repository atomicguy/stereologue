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
    @Environment(\.catalogQueryService) private var queryService
    @Environment(UserDataService.self) private var userDataService

    @State private var rows: [CardRow] = []
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if hasLoaded {
                CardGridView(
                    rows: rows,
                    emptyTitle: "No Favorites",
                    emptySystemImage: "heart",
                    emptyDescription: "Cards you favorite will appear here."
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Favorites")
        // Keyed on the reactive favorite list, so the grid refetches whenever
        // favorites change anywhere. The catalog lookup runs off the main actor.
        .task(id: userDataService.favoriteUUIDs) {
            rows = await queryService?.cardRows(uuids: userDataService.favoriteUUIDs) ?? []
            hasLoaded = true
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
