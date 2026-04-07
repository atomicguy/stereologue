//
//  CreatorsListView.swift
//  Stereologue
//
//  Browse creators in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData
import NukeUI

struct CreatorsListView: View {
    @Query(sort: \Creator.name) private var creators: [Creator]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(creators, id: \.name) { creator in
                    NavigationLink(value: creator) {
                        CreatorGridItemView(creator: creator)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Creators")
    }
}

// MARK: - Grid Item

private struct CreatorGridItemView: View {
    let creator: Creator

    private let aspectRatio: CGFloat = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Thumbnail mosaic with count badge
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    mosaicGrid
                }
                .overlay(alignment: .bottomTrailing) {
                    countBadge
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // Creator name
            Text(creator.name)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - 2×2 Mosaic

    private var mosaicGrid: some View {
        let displayCards = Array(creator.cards.prefix(4))

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
        Text("\(creator.cardCount)")
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
        CreatorsListView()
    }
    .previewEnvironment()
}
#endif
