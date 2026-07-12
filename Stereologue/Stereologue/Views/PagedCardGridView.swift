//
//  PagedCardGridView.swift
//  Stereologue
//
//  A card grid backed by a *paged* catalog query instead of a pre-faulted
//  relationship array. Opening a prolific creator/subject/place/collection
//  otherwise faults every related card into memory on the main thread at once;
//  this materializes one page at a time and grows as the user scrolls.
//

import SwiftUI
import SwiftData

struct PagedCardGridView: View {
    let predicate: Predicate<StereoCard>
    var emptyTitle: String = "No Cards"
    var emptySystemImage: String = "photo.on.rectangle.angled"
    var emptyDescription: String = "No cards to display."

    /// Number of cards fetched per page. The first page appears immediately;
    /// scrolling near the end grows the limit, which refetches the next page.
    private static let pageSize = 60

    @State private var limit = PagedCardGridView.pageSize

    var body: some View {
        PagedCardGrid(
            predicate: predicate,
            limit: limit,
            emptyTitle: emptyTitle,
            emptySystemImage: emptySystemImage,
            emptyDescription: emptyDescription,
            onReachEnd: { limit += Self.pageSize }
        )
    }
}

/// Inner view whose `@Query` is rebuilt whenever `limit` changes. Bounded by
/// `fetchLimit`, so only the visible pages are materialized on the main context.
private struct PagedCardGrid: View {
    @Query private var cards: [StereoCard]

    private let limit: Int
    private let emptyTitle: String
    private let emptySystemImage: String
    private let emptyDescription: String
    private let onReachEnd: () -> Void

    init(
        predicate: Predicate<StereoCard>,
        limit: Int,
        emptyTitle: String,
        emptySystemImage: String,
        emptyDescription: String,
        onReachEnd: @escaping () -> Void
    ) {
        var descriptor = FetchDescriptor<StereoCard>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.uuid)]
        )
        descriptor.fetchLimit = limit
        _cards = Query(descriptor)

        self.limit = limit
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
        self.onReachEnd = onReachEnd
    }

    var body: some View {
        CardGridView(
            cards: cards,
            emptyTitle: emptyTitle,
            emptySystemImage: emptySystemImage,
            emptyDescription: emptyDescription,
            // Only ask for more when this page came back full — a short page
            // means every matching card is already materialized.
            onReachEnd: cards.count == limit ? onReachEnd : nil
        )
    }
}
