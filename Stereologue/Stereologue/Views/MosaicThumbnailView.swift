//
//  MosaicThumbnailView.swift
//  Stereologue
//
//  A 2×2 mosaic of card thumbnails used in browse lists.
//

import SwiftUI
import NukeUI

struct MosaicThumbnailView: View {
    let cards: [StereoCard]

    private let mosaicSize: CGFloat = 80

    var body: some View {
        let displayCards = Array(cards.prefix(4))

        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                mosaicCell(displayCards.indices.contains(0) ? displayCards[0] : nil)
                mosaicCell(displayCards.indices.contains(1) ? displayCards[1] : nil)
            }
            GridRow {
                mosaicCell(displayCards.indices.contains(2) ? displayCards[2] : nil)
                mosaicCell(displayCards.indices.contains(3) ? displayCards[3] : nil)
            }
        }
        .frame(width: mosaicSize, height: mosaicSize)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func mosaicCell(_ card: StereoCard?) -> some View {
        if let card, let url = card.frontImageURL(quality: "t") {
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
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    MosaicThumbnailView(cards: PreviewSampleData.sampleCards)
        .padding()
        .previewEnvironment()
}
#endif
