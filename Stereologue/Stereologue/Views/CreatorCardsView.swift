//
//  CreatorCardsView.swift
//  Stereologue
//
//  Grid of cards for a given creator.
//

import SwiftUI

struct CreatorCardsView: View {
    let creator: Creator

    var body: some View {
        CardGridView(
            cards: creator.cards,
            emptyTitle: "No Cards",
            emptySystemImage: "person",
            emptyDescription: "No cards for this creator."
        )
        .navigationTitle(creator.name)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CreatorCardsView(creator: PreviewSampleData.sampleCreator)
    }
    .previewEnvironment()
}
#endif
