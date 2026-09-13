//
//  PagedCardRows.swift
//  Stereologue
//
//  Offset-paged accumulation of CardRows for a grid.
//

import Foundation
import Observation

/// Appends pages of rows as a grid scrolls. All state is main-actor; the
/// fetch itself runs wherever the caller's closure runs (the catalog query
/// actor in the app).
///
/// Several grid cells can appear in one frame and each ask for the next
/// page, so `loadNextPage` flips `isLoadingPage` *synchronously* before
/// anything is awaited, and pages are de-duplicated by UUID on append. Both
/// guards are needed: without the first, one page is fetched and appended
/// once per cell; without the second, any overlap from a non-total sort
/// order would still produce duplicate `ForEach` identifiers.
@Observable @MainActor
final class PagedCardRows {
    typealias Fetch = @Sendable (_ offset: Int, _ limit: Int) async -> [CardRow]

    private(set) var rows: [CardRow] = []
    private(set) var hasLoadedFirstPage = false
    private(set) var reachedEnd = false
    private(set) var isLoadingPage = false

    let pageSize: Int
    private let fetch: Fetch
    private var seen = Set<String>()
    /// Bumped on every reload so a page still in flight for an old query is
    /// dropped when it lands.
    private var generation = 0

    init(pageSize: Int = 80, fetch: @escaping Fetch) {
        self.pageSize = pageSize
        self.fetch = fetch
    }

    /// Clears everything and loads the first page.
    func reload() async {
        generation += 1
        rows = []
        seen = []
        reachedEnd = false
        hasLoadedFirstPage = false
        isLoadingPage = false
        await loadPage(generation)
    }

    /// Requests the next page unless one is already loading or the end has
    /// been reached. Safe to call from every cell's `onAppear`.
    func loadNextPage() {
        guard hasLoadedFirstPage, !isLoadingPage, !reachedEnd else { return }
        isLoadingPage = true
        let expected = generation
        Task { await loadPage(expected) }
    }

    private func loadPage(_ expected: Int) async {
        isLoadingPage = true
        let offset = rows.count
        let page = await fetch(offset, pageSize)
        guard expected == generation else { return }
        rows.append(contentsOf: page.filter { seen.insert($0.uuid).inserted })
        reachedEnd = page.count < pageSize
        hasLoadedFirstPage = true
        isLoadingPage = false
    }
}
