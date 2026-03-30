//
//  PlaceCardsView.swift
//  Stereologue
//
//  Grid of cards for a given place.
//

import SwiftUI

struct PlaceCardsView: View {
    let place: Place

    var body: some View {
        CardGridView(
            cards: place.cards,
            emptyTitle: "No Cards",
            emptySystemImage: "mappin.and.ellipse",
            emptyDescription: "No cards for this place."
        )
        .navigationTitle(place.name)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        PlaceCardsView(place: PreviewSampleData.samplePlace)
    }
    .previewEnvironment()
}
#endif
