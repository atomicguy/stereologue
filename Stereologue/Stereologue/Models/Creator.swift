//
//  Creator.swift
//  Stereologue
//
//  Normalized creator/photographer model (~1,744 unique).
//  Many cards share the same creator. One-to-many relationship.
//

import Foundation
import SwiftData

@Model
final class Creator {

    #Unique<Creator>([\.name])

    #Index<Creator>([\.name])

    var name: String

    @Relationship(inverse: \StereoCard.creator)
    var cards: [StereoCard] = []

    var cardCount: Int {
        cards.count
    }

    init(name: String = "") {
        self.name = name
    }
}
