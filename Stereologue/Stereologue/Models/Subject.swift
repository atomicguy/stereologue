//
//  Subject.swift
//  Retroview
//
//  Created by Adam Schuster on 4/20/24.
//

import Foundation
import SwiftData

enum SubjectSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Subject.self, CardSchemaV1.StereoCard.self]
    }

    @Model
    class Subject {
        var name: String
        var cards: [CardSchemaV1.StereoCard] = []
        @Attribute(.externalStorage) var thumbnailData: Data?

        init(name: String) {
            self.name = name
        }
    }
}
