//
//  CollectionCardsView.swift
//  Stereologue
//
//  Grid of cards for a given collection.
//

import SwiftUI
import SwiftData

struct CollectionCardsView: View {
    let collection: Collection

    var body: some View {
        PagedCardGridView(
            predicate: predicate,
            emptyTitle: "No Cards",
            emptySystemImage: "building.columns",
            emptyDescription: "No cards in this collection."
        )
        .navigationTitle(collection.name)
    }

    private var predicate: Predicate<StereoCard> {
        let name = collection.name
        return #Predicate<StereoCard> { $0.collection?.name == name }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CollectionCardsView(collection: PreviewSampleData.sampleCollection)
    }
    .previewEnvironment()
}
#endif
