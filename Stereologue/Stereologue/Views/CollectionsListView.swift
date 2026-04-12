//
//  CollectionsListView.swift
//  Stereologue
//
//  Browse collections in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData
import Nuke
import NukeUI

struct CollectionsListView: View {
    @Query(sort: \Collection.name) private var collections: [Collection]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(collections, id: \.name) { collection in
                    NavigationLink(value: collection) {
                        CollectionGridItemView(collection: collection)
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
    let collection: Collection

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

            Text(collection.name)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - 2×2 Mosaic

    private var mosaicGrid: some View {
        let displayCards = Array(collection.cards.prefix(4))

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
        if let card, let url = card.frontImageURL(quality: "b") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemFill)
                }
            }
            .processors([.resize(width: 150)])
            .priority(.low)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color(.systemFill)
        }
    }

    // MARK: - Count Badge

    private var countBadge: some View {
        Text("\(collection.cardCount)")
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
