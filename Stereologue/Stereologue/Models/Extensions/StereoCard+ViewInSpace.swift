//
//  StereoCard+ViewInSpace.swift
//  Retroview
//
//  Created by Adam Schuster on 1/5/25.
//

import QuickLook
import SwiftUI

#if os(visionOS)
    import SwiftUI
    import QuickLook

    extension CardSchemaV1.StereoCard {
        func viewInSpace(
            imageLoader: CardImageLoader,
            onStateChange: ((Bool) -> Void)? = nil
        ) async {
            onStateChange?(true)
            defer { onStateChange?(false) }

            do {
                // Just check if we can load the image successfully
                guard
                    try await imageLoader.loadImage(
                        for: self,
                        side: .front,
                        quality: .ultra
                    ) != nil
                else { return }

                let _ = try await PreviewApplication.openCards(
                    [self],
                    selectedCard: self,
                    imageLoader: imageLoader
                )
            } catch {
                print("Failed to open card in space: \(error)")
            }
        }
    }
#endif
