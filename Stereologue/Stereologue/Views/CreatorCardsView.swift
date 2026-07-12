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
        PagedCardGridView(
            predicate: predicate,
            emptyTitle: "No Cards",
            emptySystemImage: "person",
            emptyDescription: "No cards for this creator."
        )
        .navigationTitle(creator.name)
    }

    private var predicate: Predicate<StereoCard> {
        let name = creator.name
        return #Predicate<StereoCard> { $0.creator?.name == name }
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
