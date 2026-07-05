//
//  Creator.swift
//  Stereologue
//
//  Normalized creator/photographer model (~1,744 unique).
//  Many cards share the same creator. One-to-many relationship.
//

import Foundation
import SwiftData

// `nonisolated` so the model is readable from `CatalogQueryService`'s
// background `@ModelActor` context (the project defaults to MainActor).
@Model
nonisolated final class Creator {

    #Unique<Creator>([\.name])

    #Index<Creator>([\.name])

    var name: String

    @Relationship(inverse: \StereoCard.creator)
    var cards: [StereoCard] = []

    /// Denormalized count of related cards. Populated at import/migration and
    /// backfilled on first launch (see `CatalogQueryService`), so browse tiles
    /// can show the badge without an unbounded per-tile count query.
    var cardCount: Int = 0

    init(name: String = "") {
        self.name = name
    }
}
