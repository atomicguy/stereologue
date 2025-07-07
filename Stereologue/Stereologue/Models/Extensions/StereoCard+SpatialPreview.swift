//
//  StereoCard+SpatialPreview.swift
//  Retroview
//
//  Created by Adam Schuster on 12/31/24.
//

#if os(visionOS)
    import Foundation
    import QuickLook

    extension CardSchemaV1.StereoCard {
        func getOrCreatePreviewItem(sourceImage: CGImage) async throws
            -> PreviewItem
        {
            let manager = SpatialPhotoManager(modelContext: modelContext!)
            let spatialData = try await manager.getSpatialPhotoData(
                for: self, sourceImage: sourceImage)

            // Only write to temp file when needed for preview
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(uuid.uuidString)
                .appendingPathExtension("heic")
            try spatialData.write(to: url)

            return PreviewItem(
                url: url, displayName: titlePick?.text ?? "Untitled Card")
        }
    }
#endif
