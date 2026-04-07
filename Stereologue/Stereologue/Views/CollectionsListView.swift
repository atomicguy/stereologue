//
//  CollectionsListView.swift
//  Stereologue
//
//  Browse collections in a grid with mosaic thumbnails.
//  Collections are derived from the `collection` string on StereoCard.
//

import SwiftUI
import SwiftData
import NukeUI

/// Lightweight value type for navigating to a collection's cards.
struct CollectionDestination: Hashable {
    let name: String
}

struct CollectionsListView: View {
    @Query(sort: \StereoCard.collection) private var allCards: [StereoCard]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    /// Cards grouped by collection name, sorted alphabetically.
    private var collections: [(name: String, cards: [StereoCard])] {
        let grouped = Dictionary(grouping: allCards.filter { $0.collection != nil }) {
            $0.collection!
        }
        return grouped
            .map { (name: $0.key, cards: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(collections, id: \.name) { collection in
                    NavigationLink(value: CollectionDestination(name: collection.name)) {
                        CollectionGridItemView(
                            name: collection.name,
                            cards: collection.cards
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Collections")
    }
}

// MARK: - Grid Item

private struct CollectionGridItemView: View {
    let name: String
    let cards: [StereoCard]

    private let aspectRatio: CGFloat = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    mosaicGrid
                }
                .overlay(alignment: .bottomTrailing) {
                    countBadge
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                .hoverEffect(.lift)

            Text(name)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - 2×2 Mosaic

    private var mosaicGrid: some View {
        let displayCards = Array(cards.prefix(4))

        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                mosaicCell(displayCards.indices.contains(0) ? displayCards[0] : nil)
                mosaicCell(displayCards.indices.contains(1) ? displayCards[1] : nil)
            }
            GridRow {
                mosaicCell(displayCards.indices.contains(2) ? displayCards[2] : nil)
                mosaicCell(displayCards.indices.contains(3) ? displayCards[3] : nil)
            }
        }
    }

    @ViewBuilder
    private func mosaicCell(_ card: StereoCard?) -> some View {
        if let card, let url = card.frontImageURL(quality: "r") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemFill)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color(.systemFill)
        }
    }

    // MARK: - Count Badge

    private var countBadge: some View {
        Text("\(cards.count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CollectionsListView()
    }
    .previewEnvironment()
}
#endif
