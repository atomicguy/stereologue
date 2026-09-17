//
//  CardThumbnailView.swift
//  Stereologue
//
//  Displays a thumbnail of a stereoview card's front image using Nuke.
//

import SwiftUI
import Nuke

struct CardThumbnailView: View {
    let row: CardRow

    /// The Nuke request for a thumbnail.
    ///
    /// `.pixels` is essential: `.resize(width:)` defaults to `.points`,
    /// which multiplies by the screen scale and makes the resize a no-op,
    /// decoding the full-size source and inflating the memory cache cost.
    /// 160px comfortably fills the 80×50pt frame at typical display scales.
    static func thumbnailRequest(for row: CardRow) -> ImageRequest? {
        guard let url = row.frontImageURL(quality: "f") else { return nil }
        return ImageRequest(url: url, processors: [.resize(width: 160, unit: .pixels)])
    }

    var body: some View {
        ReloadableImage(request: Self.thumbnailRequest(for: row), priority: .low) { image in
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: { phase in
            placeholder
                .overlay {
                    if case .failed(let reload) = phase {
                        ImageReloadButton(showsLabel: false, action: reload)
                    }
                }
        }
        .frame(width: 80, height: 50)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(.placeholderFill)
            .frame(width: 80, height: 50)
            .overlay {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
    }
}

#if DEBUG
#Preview(traits: .sizeThatFitsLayout) {
    CardThumbnailView(row: CardRow(PreviewSampleData.sampleCard))
        .padding()
        .previewEnvironment()
}
#endif
