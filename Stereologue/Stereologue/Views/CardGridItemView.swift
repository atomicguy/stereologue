//
//  CardGridItemView.swift
//  Stereologue
//
//  A grid cell showing a stereoview card thumbnail with title overlay.
//

import SwiftUI
import Nuke
import NukeUI

struct CardGridItemView: View {
    let card: StereoCard

    /// Stereoview cards are roughly 7×3.5 inches, so ~2:1 aspect ratio for the front.
    private let aspectRatio: CGFloat = 1.6

    /// The Nuke request used to load a grid thumbnail.
    ///
    /// Shared by `CardGridView`'s prefetcher so the prefetched, decoded, and
    /// resized image lands in the memory cache under the *same* key the cell
    /// requests — otherwise the prefetch work is wasted on a redundant decode.
    /// Sources the 300px IIIF rendition (`r`) for fast cold-open and low
    /// bandwidth, decoded to a 300px-wide bitmap. The `.pixels` unit is
    /// essential: `.resize(width:)` defaults to `.points`, which multiplies by
    /// the screen scale (→600px on a 2× display), exceeds the 300px source, and
    /// makes the resize a no-op — Nuke would still decode at native size, but
    /// pinning the bitmap to 300px keeps the memory cache's cost math healthy.
    static func thumbnailRequest(for card: StereoCard) -> ImageRequest? {
        guard let url = card.frontImageURL(quality: "r") else { return nil }
        return ImageRequest(url: url, processors: [.resize(width: 300, unit: .pixels)])
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                imageContent
            }
            .overlay(alignment: .bottom) {
                titleOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            #if os(iOS) || os(visionOS)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 12))
            .hoverEffect(.lift)
            #endif
    }

    @ViewBuilder
    private var imageContent: some View {
        if let request = Self.thumbnailRequest(for: card) {
            LazyImage(request: request) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    placeholderContent
                } else {
                    placeholderContent
                }
            }
            .priority(.normal)
            .transition(.opacity)
        } else {
            placeholderContent
        }
    }

    private var titleOverlay: some View {
        Text(card.title)
            .font(.caption)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
    }

    private var placeholderContent: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    CardGridItemView(card: PreviewSampleData.sampleCard)
        .frame(width: 240)
        .previewEnvironment()
}
#endif
