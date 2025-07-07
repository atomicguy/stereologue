//
//  StereoCard+URL.swift
//  Retroview
//
//  Created by Adam Schuster on 1/9/25.
//

import Foundation
import UniformTypeIdentifiers

extension CardSchemaV1.StereoCard {
    func createSharingURL() -> URL? {
        guard let spatialData = spatialPhotoData else { return nil }

        let title = titlePick?.text ?? "Untitled Card"
        // Sanitize filename by removing invalid characters
        let sanitizedTitle = title.replacingOccurrences(
            of: "[/\\?%*|\"<>]", with: "-", options: .regularExpression)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitizedTitle)
            .appendingPathExtension("heic")

        do {
            try spatialData.write(to: tempURL)
            // Set UTType for HEIC image
            try (tempURL as NSURL).setResourceValue(
                UTType.heic.identifier,
                forKey: .typeIdentifierKey
            )
            // Set as image content type
            try (tempURL as NSURL).setResourceValue(
                UTType.image.identifier,
                forKey: .contentTypeKey
            )
            // Mark as readable to other apps
            try (tempURL as NSURL).setResourceValue(
                true,
                forKey: .isReadableKey
            )
            return tempURL
        } catch {
            print("Failed to create sharing URL: \(error)")
            return nil
        }
    }
}
