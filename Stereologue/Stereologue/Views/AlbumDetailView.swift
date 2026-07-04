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
        .onAppear { loadCards() }
    }

    private func loadCards() {
        let uuids = album.cardUUIDs
        guard !uuids.isEmpty else {
            cards = []
            return
        }

        // Fetch only this album's cards via an indexed predicate, rather than
        // loading the whole catalog and filtering in memory.
        let descriptor = FetchDescriptor<StereoCard>(
            predicate: #Predicate { uuids.contains($0.uuid) }
        )
        let matched = (try? catalogContext.fetch(descriptor)) ?? []

        // Preserve the album sort order
        let orderMap = Dictionary(uniqueKeysWithValues: uuids.enumerated().map { ($1, $0) })
        cards = matched.sorted { (orderMap[$0.uuid] ?? 0) < (orderMap[$1.uuid] ?? 0) }
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
