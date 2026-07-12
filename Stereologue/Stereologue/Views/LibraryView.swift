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
    @State private var debouncedSearchText = ""

    var body: some View {
        LibraryGrid(searchText: debouncedSearchText)
            .navigationTitle("Stereologue")
            .searchable(text: $searchText, prompt: "Cards, subjects, creators…")
            // Debounce: rebuilding LibraryGrid's @Query runs a `localizedStandard-
            // Contains` scan over the whole 41K-card catalog (title isn't indexed)
            // on the main context. Rebuild only after typing pauses, not on every
            // keystroke. Clearing the field applies immediately.
            .task(id: searchText) {
                if searchText.isEmpty {
                    debouncedSearchText = ""
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                debouncedSearchText = searchText
            }
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
