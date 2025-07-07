//
//  Date.swift
//  Retroview
//
//  Created by Adam Schuster on 4/20/24.
//

import Foundation
import SwiftData

enum DateSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Date.self, CardSchemaV1.StereoCard.self]
    }

    @Model
    class Date {
        var text: String
        var cards: [CardSchemaV1.StereoCard] = []
        @Attribute(.externalStorage) var thumbnailData: Data?

        init(text: String) {
            self.text = text
        }
    }
}

