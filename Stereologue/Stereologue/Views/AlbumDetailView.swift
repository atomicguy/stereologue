//
//  AlbumDetailView.swift
//  Stereologue
//
//  Grid of cards belonging to a user album.
//  Bridges the user container (album entries) and catalog container (cards).
//

import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: UserAlbum
    @Environment(\.modelContext) private var catalogContext

    @State private var cards: [StereoCard] = []

    var body: some View {
        CardGridView(
            cards: cards,
            emptyTitle: "Empty Album",
            emptySystemImage: "rectangle.stack",
            emptyDescription: "Add cards to this album from the card detail view."
        )
        .navigationTitle(album.name)
        // Keyed on the album's card list, so the grid refetches when cards are
        // added or removed rather than only on first appearance.
        .task(id: album.cardUUIDs) {
            cards = catalogContext.cards(matching: album.cardUUIDs)
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        AlbumDetailView(album: PreviewSampleData.sampleAlbum)
    }
    .previewEnvironment()
}
#endif
