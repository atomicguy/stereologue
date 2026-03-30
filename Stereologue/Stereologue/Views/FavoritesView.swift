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
        .onAppear { loadFavorites() }
    }

    private func loadFavorites() {
        let uuids = userDataService.allFavoriteUUIDs()
        guard !uuids.isEmpty else {
            favoriteCards = []
            return
        }

        // Fetch all cards, then filter in-memory.
        // SwiftData #Predicate has limitations with captured collections,
        // and with uuid indexed this is fast even for 41K records.
        var descriptor = FetchDescriptor<StereoCard>()
        descriptor.propertiesToFetch = [\.uuid, \.title, \.frontImageID]
        let allCards = (try? catalogContext.fetch(FetchDescriptor<StereoCard>())) ?? []
        let uuidSet = Set(uuids)
        let matched = allCards.filter { uuidSet.contains($0.uuid) }

        // Preserve the favorited-at ordering
        let orderMap = Dictionary(uniqueKeysWithValues: uuids.enumerated().map { ($1, $0) })
        favoriteCards = matched.sorted { (orderMap[$0.uuid] ?? 0) < (orderMap[$1.uuid] ?? 0) }
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
