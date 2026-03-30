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

        let allCards = (try? catalogContext.fetch(FetchDescriptor<StereoCard>())) ?? []
        let uuidSet = Set(uuids)
        let matched = allCards.filter { uuidSet.contains($0.uuid) }

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
