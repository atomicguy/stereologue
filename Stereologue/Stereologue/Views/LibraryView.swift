//
//  LibraryView.swift
//  Stereologue
//
//  Grid of all stereoview cards in the catalog.
//

import SwiftUI
import SwiftData

struct LibraryView: View {
    @State private var searchText = ""

    var body: some View {
        LibraryGrid(searchText: searchText)
            .navigationTitle("Stereologue")
            .searchable(text: $searchText, prompt: "Cards, subjects, creators…")
    }
}

/// Grid whose `@Query` is rebuilt from `searchText`, so filtering happens in
/// the store rather than materializing the whole 41K-card catalog in memory.
private struct LibraryGrid: View {
    @Query private var cards: [StereoCard]
    private let searchText: String

    init(searchText: String) {
        self.searchText = searchText
        var descriptor = FetchDescriptor<StereoCard>()
        if !searchText.isEmpty {
            descriptor.predicate = #Predicate { $0.title.localizedStandardContains(searchText) }
        }
        _cards = Query(descriptor)
    }

    var body: some View {
        CardGridView(
            cards: cards,
            emptyTitle: searchText.isEmpty ? "No Cards" : "No Results",
            emptySystemImage: searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
            emptyDescription: searchText.isEmpty
                ? "The catalog could not be loaded."
                : "No cards match \"\(searchText)\"."
        )
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        LibraryView()
    }
    .previewEnvironment()
}
#endif
