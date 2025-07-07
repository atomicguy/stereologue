//
//  Crop.swift
//  Retroview
//
//  Created by Adam Schuster on 4/21/24.
//

import Foundation
import SwiftData

enum CropSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Crop.self]
    }

    enum Side: String {
        case left
        case right
    }

    @Model
    class Crop {
        var x0: Float
        var y0: Float
        var x1: Float
        var y1: Float
        var score: Float
        var side: String

        @Relationship(deleteRule: .cascade)
        var card: CardSchemaV1.StereoCard?

        init(
            x0: Float,
            y0: Float,
            x1: Float,
            y1: Float,
            score: Float,
            side: String
        ) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
            self.score = score
            self.side = side
        }
    }
}

extension CropSchemaV1.Crop {
    var description: String {
        "(\(x0),\(y0))->(\(x1),\(y1))"
    }
}
