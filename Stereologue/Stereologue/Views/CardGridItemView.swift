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
        if let url = card.frontImageURL(quality: "r") {
            LazyImage(url: url) { state in
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
            .processors([.resize(width: 300)])
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
