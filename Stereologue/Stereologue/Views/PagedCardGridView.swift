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

    @Environment(\.catalogQueryService) private var queryService

    @State private var loader: PagedCardRows?
    /// The `queryKey` the current loader was built for. Guards against
    /// reloading (and losing scroll position) when the grid merely reappears
    /// after a navigation pop.
    @State private var loadedKey: String?

    var body: some View {
        Group {
            if let loader, loader.hasLoadedFirstPage {
                CardGridView(
                    rows: loader.rows,
                    emptyTitle: emptyTitle,
                    emptySystemImage: emptySystemImage,
                    emptyDescription: emptyDescription,
                    onReachEnd: loader.reachedEnd ? nil : { loader.loadNextPage() }
                )
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: queryKey) {
            guard loadedKey != queryKey else { return }
            loadedKey = queryKey
            let loader = PagedCardRows(fetch: makeFetch())
            self.loader = loader
            await loader.reload()
        }
    }

    private func makeFetch() -> PagedCardRows.Fetch {
        let predicate = predicate
        let sortBy = sortBy
        let queryService = queryService
        return { offset, limit in
            guard let queryService else { return [] }
            return await queryService.cardRows(
                matching: predicate, sortBy: sortBy, offset: offset, limit: limit
            )
        }
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
