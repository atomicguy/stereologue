//
//  PlacesListView.swift
//  Stereologue
//
//  Browse places with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct PlacesListView: View {
    @Query(sort: \Place.name) private var places: [Place]

    var body: some View {
        List(places, id: \.name) { place in
            NavigationLink(value: place) {
                HStack(spacing: 12) {
                    MosaicThumbnailView(cards: place.cards)
                    VStack(alignment: .leading) {
                        Text(place.name)
                            .font(.headline)
                        Text("^[\(place.cardCount) card](inflect: true)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Places")
    }
}
#if DEBUG
#Preview(traits: .fixedLayout(width: 400, height: 700)) {
    NavigationStack {
        PlacesListView()
    }
    .previewEnvironment()
}
#endif

