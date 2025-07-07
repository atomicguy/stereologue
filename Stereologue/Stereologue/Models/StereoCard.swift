//
//  StereoCard.swift
//  Retroview
//
//  Created by Adam Schuster on 4/6/24.
//

import Foundation
import SwiftData
import SwiftUI

enum CardSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version = .init(0, 1, 0)

    static var models: [any PersistentModel.Type] {
        [
            CardSchemaV1.StereoCard.self,
            TitleSchemaV1.Title.self,
            AuthorSchemaV1.Author.self,
            SubjectSchemaV1.Subject.self,
            DateSchemaV1.Date.self,
        ]
    }

    @Model
    class StereoCard {
        // MARK: - Core Properties
        @Attribute(.unique) var uuid: UUID
        var imageFrontId: String?
        var imageBackId: String?
        var cardColor: String = "#F5E6D3"
        var colorOpacity: Double

        // MARK: - Image Storage
        @Attribute(.externalStorage) var frontThumbnailData: Data?
        @Attribute(.externalStorage) var frontStandardData: Data?
        @Attribute(.externalStorage) var backThumbnailData: Data?
        @Attribute(.externalStorage) var backStandardData: Data?
        @Attribute(.externalStorage) var spatialPhotoData: Data?

        // MARK: - Relationships
        @Relationship(deleteRule: .cascade, inverse: \TitleSchemaV1.Title.cards)
        var titles = [TitleSchemaV1.Title]()

        @Relationship(deleteRule: .nullify, inverse: \TitleSchemaV1.Title.picks)
        var titlePick: TitleSchemaV1.Title?

        @Relationship(inverse: \AuthorSchemaV1.Author.cards)
        var authors = [AuthorSchemaV1.Author]()

        @Relationship(inverse: \SubjectSchemaV1.Subject.cards)
        var subjects = [SubjectSchemaV1.Subject]()

        @Relationship(inverse: \DateSchemaV1.Date.cards)
        var dates = [DateSchemaV1.Date]()

        var collections: [CollectionSchemaV1.Collection] = []

        @Relationship(deleteRule: .cascade)
        var crops: [CropSchemaV1.Crop] = []

        // MARK: - Computed Properties
        var leftCrop: CropSchemaV1.Crop? {
            get { crops.first { $0.side == CropSchemaV1.Side.left.rawValue } }
            set {
                if let existingIndex = crops.firstIndex(where: {
                    $0.side == CropSchemaV1.Side.left.rawValue
                }) {
                    crops.remove(at: existingIndex)
                }
                if let newCrop = newValue {
                    crops.append(newCrop)
                    newCrop.card = self
                }
            }
        }

        var rightCrop: CropSchemaV1.Crop? {
            get { crops.first { $0.side == CropSchemaV1.Side.right.rawValue } }
            set {
                if let existingIndex = crops.firstIndex(where: {
                    $0.side == CropSchemaV1.Side.right.rawValue
                }) {
                    crops.remove(at: existingIndex)
                }
                if let newCrop = newValue {
                    crops.append(newCrop)
                    newCrop.card = self
                }
            }
        }

        var color: Color {
            get {
                (Color(hex: cardColor) ?? Color(hex: "#F5E6D3")!)
                    .opacity(colorOpacity)
            }
            set {
                cardColor = newValue.toHex() ?? "#F5E6D3"
                colorOpacity = 0.15
            }
        }

        // Computed property for temporary URL access when needed
        var temporarySpatialPhotoURL: URL? {
            guard let data = spatialPhotoData else { return nil }

            // Create URL in temporary directory
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(uuid.uuidString)
                .appendingPathExtension("heic")

            try? data.write(to: url)
            return url
        }

        // MARK: - Initialization
        init(
            uuid: UUID,
            imageFrontId: String? = nil,
            imageBackId: String? = nil,
            cardColor: String = "#F5E6D3",
            colorOpacity: Double = 0.15,
            titles: [TitleSchemaV1.Title] = [],
            authors: [AuthorSchemaV1.Author] = [],
            subjects: [SubjectSchemaV1.Subject] = [],
            dates: [DateSchemaV1.Date] = [],
            crops: [CropSchemaV1.Crop] = []
        ) {
            self.uuid = uuid
            self.imageFrontId = imageFrontId
            self.imageBackId = imageBackId
            self.cardColor = cardColor
            self.colorOpacity = colorOpacity
            self.titles = titles
            self.authors = authors
            self.subjects = subjects
            self.dates = dates
            self.crops = crops

            self.frontThumbnailData = nil
            self.frontStandardData = nil
            self.backThumbnailData = nil
            self.backStandardData = nil
        }
    }
}

// MARK: - Transferable Conformance
extension CardSchemaV1.StereoCard: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation<CardSchemaV1.StereoCard, String>(exporting: {
            card in
            card.uuid.uuidString
        })
    }
}
