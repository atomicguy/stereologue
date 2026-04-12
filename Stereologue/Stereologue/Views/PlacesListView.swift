//
//  PlacesListView.swift
//  Stereologue
//
//  Browse places in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData
import Nuke
import NukeUI

struct PlacesListView: View {
    @Query(sort: \Place.name) private var places: [Place]

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(places, id: \.name) { place in
                    NavigationLink(value: place) {
                        PlaceGridItemView(place: place)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Places")
    }
}

// MARK: - Grid Item

private struct PlaceGridItemView: View {
    let place: Place

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

            // Place name
            Text(place.name)
                .font(.caption)
                .lineLimit(2)
        }
    }

    // MARK: - 2×2 Mosaic

    private var mosaicGrid: some View {
        let displayCards = Array(place.cards.prefix(4))

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
        Text("\(place.cardCount)")
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
        PlacesListView()
    }
    .previewEnvironment()
}
#endif
