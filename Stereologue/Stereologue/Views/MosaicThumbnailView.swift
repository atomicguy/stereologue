//
//  MosaicThumbnailView.swift
//  Stereologue
//
//  A 2×2 mosaic of card thumbnails used in browse lists.
//

import SwiftUI
import SwiftData
import Nuke
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
        if let card, let url = card.frontImageURL(quality: "b") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemFill)
                }
            }
            .processors([.resize(width: 80)])
            .priority(.low)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color(.systemFill)
        }
    }
}

// MARK: - Browse List Cell

/// A browse-list grid cell: a 2×2 thumbnail mosaic with a card-count badge and
/// a title, used by the Subjects/Creators/Places/Collections lists.
///
/// The count and the four preview cards come from bounded fetches (`fetchCount`
/// and a `fetchLimit`-4 fetch) keyed off the entity's name, rather than reading
/// `entity.cards`, which would fault the entity's *entire* to-many relationship
/// (potentially thousands of cards) just to show four thumbnails and a number.
struct BrowseMosaicItem: View {
    let title: String
    let cardPredicate: Predicate<StereoCard>

    @Environment(\.modelContext) private var context
    @State private var previewCards: [StereoCard] = []
    @State private var count = 0

    private let aspectRatio: CGFloat = 1.6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay { mosaic }
                .overlay(alignment: .bottomTrailing) { countBadge }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                #if os(iOS) || os(visionOS)
                .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
                .hoverEffect(.lift)
                #endif

            Text(title)
                .font(.caption)
                .lineLimit(2)
        }
        .task(id: title) { load() }
    }

    private func load() {
        let countDescriptor = FetchDescriptor<StereoCard>(predicate: cardPredicate)
        count = (try? context.fetchCount(countDescriptor)) ?? 0

        var previewDescriptor = FetchDescriptor<StereoCard>(predicate: cardPredicate)
        previewDescriptor.fetchLimit = 4
        previewCards = (try? context.fetch(previewDescriptor)) ?? []
    }

    private var mosaic: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                mosaicCell(previewCards.indices.contains(0) ? previewCards[0] : nil)
                mosaicCell(previewCards.indices.contains(1) ? previewCards[1] : nil)
            }
            GridRow {
                mosaicCell(previewCards.indices.contains(2) ? previewCards[2] : nil)
                mosaicCell(previewCards.indices.contains(3) ? previewCards[3] : nil)
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
            .processors([.resize(width: 150, unit: .pixels)])
            .priority(.low)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else {
            Color(.systemFill)
        }
    }

    private var countBadge: some View {
        Text("\(count)")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(6)
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    MosaicThumbnailView(cards: PreviewSampleData.sampleCards)
        .padding()
        .previewEnvironment()
}
#endif
