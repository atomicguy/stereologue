//
//  CollectionCardsView.swift
//  Stereologue
//
//  Grid of cards for a given collection.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collectionName: String

    @Query private var cards: [StereoCard]

    init(collectionName: String) {
        self.collectionName = collectionName
        _cards = Query(
            filter: #Predicate<StereoCard> { card in
                card.collection == collectionName
            },
            sort: \.title
        )
    }

    var body: some View {
        CardGridView(
            cards: cards,
            emptyTitle: "No Cards",
            emptySystemImage: "building.columns",
            emptyDescription: "No cards in this collection."
        )
        .navigationTitle(collectionName)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CollectionCardsView(collectionName: "Robert N. Dennis Collection")
    }
    .previewEnvironment()
}
#endif
