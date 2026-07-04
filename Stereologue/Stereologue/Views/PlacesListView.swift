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

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(places, id: \.name) { place in
                    let name = place.name
                    NavigationLink(value: place) {
                        BrowseMosaicItem(
                            title: name,
                            cardPredicate: #Predicate { card in
                                card.places.contains { $0.name == name }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
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
