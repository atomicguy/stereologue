//
//  CardGridView.swift
//  Stereologue
//
//  Reusable adaptive grid of card rows with navigation links.
//

import SwiftUI
import Nuke

struct CardGridView: View {
    let rows: [CardRow]
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String
    /// Called as the user nears the end of the grid, so a paged caller can load
    /// the next page. `nil` when every row is already present.
    let onReachEnd: (() -> Void)?
    /// A destructive action offered in each cell's context menu (for example
    /// "Remove from Album"). `nil` for grids whose membership isn't editable.
    let removeAction: CardGridRemoveAction?

    @Environment(CardListContext.self) private var cardListContext
    // Prefetch into the memory cache (the default) so cells appear instantly:
    // .diskCache would only download bytes and skip the expensive decode/resize.
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache
    )

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    init(
        rows: [CardRow],
        emptyTitle: String = "No Cards",
        emptySystemImage: String = "photo.on.rectangle.angled",
        emptyDescription: String = "No cards to display.",
        onReachEnd: (() -> Void)? = nil,
        removeAction: CardGridRemoveAction? = nil
    ) {
        self.rows = rows
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
        self.onReachEnd = onReachEnd
        self.removeAction = removeAction
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        // The index is passed in with the row so a cell's
                        // appearance never has to search the array for itself.
                        ForEach(Array(rows.enumerated()), id: \.element.uuid) { index, row in
                            NavigationLink(value: row) {
                                CardGridItemView(row: row)
                                    .onAppear { onCardAppear(at: index) }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if let removeAction {
                                    Button(role: .destructive) {
                                        removeAction.perform(row)
                                    } label: {
                                        Label(removeAction.title, systemImage: removeAction.systemImage)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onAppear { cardListContext.update(rows) }
        .onChange(of: rows) { cardListContext.update(rows) }
        .onDisappear { prefetcher.stopPrefetching() }
    }

    private func onCardAppear(at index: Int) {
        // Prefetch the next 10 cards ahead, using the same request the cell
        // renders so the cache key (URL + resize processor) matches and the
        // decode/resize work is reused on display.
        let prefetchRange = (index + 1)..<min(index + 11, rows.count)
        if !prefetchRange.isEmpty {
            let requests = rows[prefetchRange].compactMap { CardGridItemView.thumbnailRequest(for: $0) }
            prefetcher.startPrefetching(with: requests)
        }

        // Ask a paged caller to load the next page just before the end, so new
        // cards are ready by the time they scroll into view.
        if let onReachEnd, index >= rows.count - 10 {
            onReachEnd()
        }
    }
}

/// A destructive per-card action a grid can offer in its context menu.
struct CardGridRemoveAction {
    let title: String
    let systemImage: String
    let perform: (CardRow) -> Void
}

#if DEBUG
#Preview("With Cards", traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CardGridView(rows: PreviewSampleData.sampleRows)
    }
    .previewEnvironment()
}

#Preview("Empty State", traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CardGridView(
            rows: [],
            emptyTitle: "No Cards",
            emptySystemImage: "photo.on.rectangle.angled",
            emptyDescription: "No cards to display."
        )
    }
    .previewEnvironment()
}
#endif
