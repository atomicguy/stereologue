//
//  Subject.swift
//  Stereologue
//
//  Normalized topic subject model (~1,789 unique).
//  Many-to-many: a card has multiple subjects, a subject has many cards.
//

import Foundation
import SwiftData

@Model
final class Subject {

    #Unique<Subject>([\.name])

    #Index<Subject>([\.name])

    var name: String

    @Relationship(inverse: \StereoCard.subjects)
    var cards: [StereoCard] = []

    var cardCount: Int {
        cards.count
    }

    init(name: String = "") {
        self.name = name
    }
}
