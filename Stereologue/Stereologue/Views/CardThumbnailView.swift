//
//  CardThumbnailView.swift
//  Stereologue
//
//  Displays a thumbnail of a stereoview card's front image using Nuke.
//

import SwiftUI
import NukeUI
import Nuke

struct CardThumbnailView: View {
    let card: StereoCard

    var body: some View {
        if let url = card.frontImageURL(quality: "f") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if state.error != nil {
                    placeholder
                } else {
                    placeholder
                }
            }
            .processors([.resize(width: 160)])
            .priority(.low)
            .transition(.opacity)
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.quaternary)
            .frame(width: 80, height: 50)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    CardThumbnailView(card: PreviewSampleData.sampleCard)
        .padding()
        .previewEnvironment()
}
#endif
