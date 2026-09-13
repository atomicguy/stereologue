//
//  PagedCardGridView.swift
//  Stereologue
//
//  A card grid backed by offset-paged `CardRow` fetches on the background
//  `CatalogQueryService`. Pages are appended as the user scrolls; earlier
//  pages are never refetched and no `@Model` instance is touched on the main
//  thread while scrolling.
//

import SwiftUI
import SwiftData

struct PagedCardGridView: View {
    /// Cards to show, or `nil` for the whole catalog.
    let predicate: Predicate<StereoCard>?
    /// Must be a total order (end with a unique key such as `uuid`) so offset
    /// paging never skips or repeats a card.
    var sortBy: [SortDescriptor<StereoCard>] = PagedCardGridView.defaultSort
    /// Change this whenever `predicate` changes (predicates aren't Equatable)
    /// so the grid resets and reloads from the first page.
    var queryKey: String = ""
    var emptyTitle: String = "No Cards"
    var emptySystemImage: String = "photo.on.rectangle.angled"
    var emptyDescription: String = "No cards to display."

    nonisolated static let defaultSort: [SortDescriptor<StereoCard>] = [
        SortDescriptor(\.title), SortDescriptor(\.uuid)
    ]

    /// Cards fetched per page. Large enough that a wide window's first screen
    /// is one round trip; small enough that the first page appears quickly.
    private static let pageSize = 80

    @Environment(\.catalogQueryService) private var queryService

    @State private var rows: [CardRow] = []
    /// The `queryKey` the current `rows` were loaded for. Guards against
    /// reloading (and losing scroll position) when the grid merely reappears
    /// after a navigation pop.
    @State private var loadedKey: String?
    @State private var reachedEnd = false
    @State private var isLoadingPage = false
    /// Bumped on every reset so a page that was in flight for an old query
    /// is dropped when it lands.
    @State private var generation = 0

    var body: some View {
        Group {
            if loadedKey == nil {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CardGridView(
                    rows: rows,
                    emptyTitle: emptyTitle,
                    emptySystemImage: emptySystemImage,
                    emptyDescription: emptyDescription,
                    onReachEnd: reachedEnd ? nil : { loadNextPage() }
                )
            }
        }
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            await reload()
        }
    }

    private func reload() async {
        generation += 1
        rows = []
        reachedEnd = false
        isLoadingPage = false
        await loadPage(generation)
    }

    private func loadNextPage() {
        guard !isLoadingPage, !reachedEnd else { return }
        let current = generation
        Task { await loadPage(current) }
    }

    private func loadPage(_ expectedGeneration: Int) async {
        guard let queryService else {
            loadedKey = queryKey
            reachedEnd = true
            return
        }
        isLoadingPage = true
        let page = await queryService.cardRows(
            matching: predicate,
            sortBy: sortBy,
            offset: rows.count,
            limit: Self.pageSize
        )
        guard expectedGeneration == generation else { return }
        rows.append(contentsOf: page)
        reachedEnd = page.count < Self.pageSize
        loadedKey = queryKey
        isLoadingPage = false
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        PagedCardGridView(predicate: nil)
    }
    .previewEnvironment()
}
#endif
