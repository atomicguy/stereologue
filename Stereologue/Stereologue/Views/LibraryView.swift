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
    #if DEBUG
    @State private var showRestorationEval = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    #endif

    var body: some View {
        LibraryGrid(searchText: debouncedSearchText)
            .navigationTitle("Stereologue")
            .searchable(text: $searchText, prompt: "Cards, subjects, creators…")
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .secondaryAction) {
                    Button("Restoration Eval", systemImage: "flask") {
                        // macOS sheets are fixed-size and clip; the tool gets a
                        // resizable window of its own there (see StereologueApp).
                        #if os(macOS)
                        openWindow(id: "restoration-eval")
                        #else
                        showRestorationEval = true
                        #endif
                    }
                }
            }
            #if !os(macOS)
            .sheet(isPresented: $showRestorationEval) {
                NavigationStack {
                    RestorationEvalView()
                }
            }
            #endif
            #endif
            // Debounce: a search runs a `localizedStandardContains` scan over
            // the whole 41K-card catalog (off the main actor, but still a full
            // scan). Rebuild only after typing pauses, not on every keystroke.
            // Clearing the field applies immediately.
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

/// Paged grid over the whole catalog (or the title search), fetched in pages
/// off the main actor so the 41K-card Library never materializes models on
/// the main thread. `queryKey` resets the pages whenever the search changes.
private struct LibraryGrid: View {
    let searchText: String

    var body: some View {
        PagedCardGridView(
            predicate: predicate,
            queryKey: searchText,
            emptyTitle: searchText.isEmpty ? "No Cards" : "No Results",
            emptySystemImage: searchText.isEmpty ? "photo.on.rectangle.angled" : "magnifyingglass",
            emptyDescription: searchText.isEmpty
                ? "The catalog could not be loaded."
                : "No cards match \"\(searchText)\"."
        )
    }

    private var predicate: Predicate<StereoCard>? {
        guard !searchText.isEmpty else { return nil }
        let text = searchText
        return #Predicate { $0.title.localizedStandardContains(text) }
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
