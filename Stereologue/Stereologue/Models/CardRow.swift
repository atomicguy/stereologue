//
//  CardRow.swift
//  Stereologue
//
//  The lightweight projection of a StereoCard that grids scroll over.
//

import Foundation

/// What a grid cell, thumbnail strip, or pager needs to know about a card,
/// as a plain Sendable value.
///
/// Grids used to iterate `[StereoCard]` straight from `@Query`, which meant the
/// Library materialized all 41K `@Model` objects on the main context and every
/// identity or index lookup faulted rows on the main thread. Rows are instead
/// fetched in pages off the main actor by `CatalogQueryService`; the full
/// model is only resolved (by indexed UUID) for the card actually being viewed.
nonisolated struct CardRow: Hashable, Identifiable, Sendable {
    let uuid: String
    let title: String
    let frontImageID: String?
    /// Whether both stereo halves were detected, so the stereo viewers and the
    /// spatial share action can be offered without touching the model.
    let hasStereoDetections: Bool

    var id: String { uuid }

    /// Returns the IIIF URL for the front of the card at the given quality.
    /// See `StereoCard.frontImageURL(quality:)` for the quality codes.
    func frontImageURL(quality: String = "w") -> URL? {
        StereoCard.iiifImageURL(id: frontImageID, quality: quality)
    }

    /// Reads the row fields from a model. Call on whichever actor owns the
    /// model's context.
    init(_ card: StereoCard) {
        uuid = card.uuid
        title = card.title
        frontImageID = card.frontImageID
        hasStereoDetections = card.leftDetection.width > 0 && card.rightDetection.width > 0
    }

    init(uuid: String, title: String, frontImageID: String?, hasStereoDetections: Bool) {
        self.uuid = uuid
        self.title = title
        self.frontImageID = frontImageID
        self.hasStereoDetections = hasStereoDetections
    }
}
