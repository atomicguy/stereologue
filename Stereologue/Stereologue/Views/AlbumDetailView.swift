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
    @Environment(\.catalogQueryService) private var queryService

    @State private var rows: [CardRow] = []
    @State private var hasLoaded = false

    var body: some View {
        Group {
            if hasLoaded {
                CardGridView(
                    rows: rows,
                    emptyTitle: "Empty Album",
                    emptySystemImage: "rectangle.stack",
                    emptyDescription: "Add cards to this album from the card detail view."
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(album.name)
        // Keyed on the album's card list, so the grid refetches when cards are
        // added or removed. The catalog lookup runs off the main actor.
        .task(id: album.cardUUIDs) {
            rows = await queryService?.cardRows(uuids: album.cardUUIDs) ?? []
            hasLoaded = true
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
