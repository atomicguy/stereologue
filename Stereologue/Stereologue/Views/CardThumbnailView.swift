//
//  CardThumbnailView.swift
//  Stereologue
//
//  Displays a thumbnail of a stereoview card's front image using Nuke.
//

import SwiftUI
import NukeUI
import Nuke
import OSLog

private let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "CardThumbnail")

struct CardThumbnailView: View {
    let card: StereoCard

    var body: some View {
        if let url = card.frontImageURL(quality: "r") {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else if let error = state.error {
                    placeholder
                        .onAppear {
                            logger.error("Failed to load image for \(card.uuid): \(error.localizedDescription)")
                            logger.error("URL was: \(url.absoluteString)")
                        }
                } else if state.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    placeholder
                }
            }
            .priority(.high)
            .onAppear {
                logger.debug("Loading thumbnail for \(card.uuid) from \(url.absoluteString)")
            }
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            placeholder
                .onAppear {
                    logger.debug("No frontImageID for card \(card.uuid) (frontImageID=\(card.frontImageID ?? "nil"))")
                }
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
