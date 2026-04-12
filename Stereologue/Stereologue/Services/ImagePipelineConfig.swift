//
//  ImagePipelineConfig.swift
//  Stereologue
//
//  Configures a shared Nuke ImagePipeline optimized for browsing
//  a large catalog of NYPL stereoview card images.
//

import Foundation
import Nuke

extension ImagePipeline {
    /// Configured pipeline for the Stereologue catalog.
    ///
    /// - 100 MB memory cache (holds ~200 grid thumbnails in memory)
    /// - 500 MB disk cache (persistent across launches)
    /// - Deduplication enabled (avoids redundant downloads for the same URL)
    /// - Progressive decoding disabled (NYPL IIIF returns complete JPEGs)
    static let stereologue: ImagePipeline = {
        var config = ImagePipeline.Configuration()

        // Memory cache: ~100 MB
        config.imageCache = ImageCache(costLimit: 100 * 1024 * 1024, countLimit: 500)

        // Disk cache: ~500 MB
        let dataCache = try? DataCache(name: "net.atompowered.Stereologue.ImageCache")
        dataCache?.sizeLimit = 500 * 1024 * 1024
        config.dataCache = dataCache

        config.isProgressiveDecodingEnabled = false

        return ImagePipeline(configuration: config)
    }()
}
