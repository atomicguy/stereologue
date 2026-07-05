//
//  PlacesListView.swift
//  Stereologue
//
//  Browse places in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct PlacesListView: View {
    @Query(sort: \Place.name) private var places: [Place]

    var body: some View {
        BrowseMosaicGrid(
            entities: places,
            id: \.name,
            title: { $0.name },
            count: \.cardCount,
            predicate: { place in
                let name = place.name
                return #Predicate { card in
                    card.places.contains { $0.name == name }
                }
            }
        )
        .navigationTitle("Places")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        PlacesListView()
    }
    .previewEnvironment()
}
#endif
