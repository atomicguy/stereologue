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
        PagedCardGridView(
            predicate: predicate,
            emptyTitle: "No Cards",
            emptySystemImage: "mappin.and.ellipse",
            emptyDescription: "No cards for this place."
        )
        .navigationTitle(place.name)
    }

    private var predicate: Predicate<StereoCard> {
        let name = place.name
        return #Predicate<StereoCard> { card in
            card.places.contains { $0.name == name }
        }
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
