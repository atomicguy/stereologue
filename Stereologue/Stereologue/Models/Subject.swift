//
//  Subject.swift
//  Stereologue
//
//  Normalized topic subject model (~1,789 unique).
//  Many-to-many: a card has multiple subjects, a subject has many cards.
//

import Foundation
import SwiftData

// `nonisolated` so the model is readable from `CatalogQueryService`'s
// background `@ModelActor` context (the project defaults to MainActor).
@Model
nonisolated final class Subject {

    #Unique<Subject>([\.name])

    #Index<Subject>([\.name])

    var name: String

    @Relationship(inverse: \StereoCard.subjects)
    var cards: [StereoCard] = []

    /// Denormalized count of related cards. Populated at import/migration and
    /// backfilled on first launch (see `CatalogQueryService`), so browse tiles
    /// can show the badge without an unbounded per-tile count query.
    var cardCount: Int = 0

    init(name: String = "") {
        self.name = name
    }
}
