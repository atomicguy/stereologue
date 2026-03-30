//
//  SearchView.swift
//  Stereologue
//
//  Search cards by title with searchable integration.
//

import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var context

    @State private var searchText = ""
    @State private var results: [StereoCard] = []

    var body: some View {
        CardGridView(
            cards: results,
            emptyTitle: searchText.isEmpty ? "Search" : "No Results",
            emptySystemImage: "magnifyingglass",
            emptyDescription: searchText.isEmpty
                ? "Search for stereoview cards by title."
                : "No cards match \"\(searchText)\"."
        )
        .navigationTitle("Search")
        .searchable(text: $searchText, prompt: "Cards, subjects, creators…")
        .onChange(of: searchText) { _, newValue in
            performSearch(query: newValue)
        }
    }

    private func performSearch(query: String) {
        guard !query.isEmpty else {
            results = []
            return
        }
        let searchTerm = query
        let descriptor = FetchDescriptor<StereoCard>(
            predicate: #Predicate<StereoCard> { card in
                card.title.localizedStandardContains(searchTerm)
            },
            sortBy: [SortDescriptor(\StereoCard.title)]
        )
        results = (try? context.fetch(descriptor)) ?? []
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        SearchView()
    }
    .previewEnvironment()
}
#endif
