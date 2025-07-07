//
//  Title.swift
//  Retroview
//
//  Created by Adam Schuster on 4/20/24.
//

import Foundation
import SwiftData

enum TitleSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TitleSchemaV1.Title.self, CardSchemaV1.StereoCard.self]
    }

    @Model
    class Title {
        var text: String
        var cards = [CardSchemaV1.StereoCard]()
        var picks = [CardSchemaV1.StereoCard]()

        init(
            text: String
        ) {
            self.text = text
        }
    }
}
