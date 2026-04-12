//
//  StereoCard.swift
//  Stereologue
//
//  Created by Adam Schuster on 7/7/25.
//

import Foundation
import SwiftData

// MARK: - Detection Data (Embedded Codable)

/// Bounding box detection for one side of a stereoview card.
/// Stored as a CompositeAttribute on StereoCard — SwiftData flattens
/// the fields into the parent table, so no join is needed.
struct ImageDetection: Codable, Hashable, Sendable {
    var detectionID: String
    var classification: String   // "left image" or "right image"
    var confidence: Double
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(
        detectionID: String = "",
        classification: String = "",
        confidence: Double = 0,
        x: Double = 0,
        y: Double = 0,
        width: Double = 0,
        height: Double = 0
    ) {
        self.detectionID = detectionID
        self.classification = classification
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    // Explicit nonisolated Codable conformance so SwiftData's
    // macro-generated persistence code can encode/decode outside
    // the main actor.
    private enum CodingKeys: String, CodingKey {
        case detectionID, classification, confidence, x, y, width, height
    }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        detectionID = try container.decode(String.self, forKey: .detectionID)
        classification = try container.decode(String.self, forKey: .classification)
        confidence = try container.decode(Double.self, forKey: .confidence)
        x = try container.decode(Double.self, forKey: .x)
        y = try container.decode(Double.self, forKey: .y)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(detectionID, forKey: .detectionID)
        try container.encode(classification, forKey: .classification)
        try container.encode(confidence, forKey: .confidence)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

// MARK: - StereoCard Model

@Model
final class StereoCard {

    #Unique<StereoCard>([\.uuid])

    #Index<StereoCard>(
        [\.uuid],
        [\.yearStart],
        [\.yearEnd],
        [\.division]
    )

    // MARK: Core Identity
    var uuid: String

    // MARK: Descriptive Metadata
    var title: String
    var physicalForm: String?
    var division: String?
    var shelfLocator: String?

    // MARK: Dates
    /// Raw date strings from the source data, preserved for display.
    var dateStartRaw: String?
    var dateEndRaw: String?
    /// Parsed integer years for indexed queries and browsing.
    var yearStart: Int?
    var yearEnd: Int?

    // MARK: Relationships
    var creator: Creator?

    var subjects: [Subject] = []

    var places: [Place] = []
    
    var collection: Collection?

    // MARK: Image IDs (NYPL IIIF)
    /// Front of card image ID, e.g. "G91F069_201ZF"
    var frontImageID: String?
    /// Back of card image ID, e.g. "G91F069_201ZB"
    var backImageID: String?

    // MARK: Image Dimensions
    var imageWidth: Double?
    var imageHeight: Double?

    // MARK: Detection Data (CompositeAttribute)
    var leftDetection: ImageDetection
    var rightDetection: ImageDetection

    init(
        uuid: String,
        title: String = "",
        dateStartRaw: String? = nil,
        dateEndRaw: String? = nil,
        yearStart: Int? = nil,
        yearEnd: Int? = nil,
        physicalForm: String? = nil,
        division: String? = nil,
        shelfLocator: String? = nil,
        frontImageID: String? = nil,
        backImageID: String? = nil,
        imageWidth: Double? = nil,
        imageHeight: Double? = nil,
        leftDetection: ImageDetection = ImageDetection(),
        rightDetection: ImageDetection = ImageDetection()
    ) {
        self.uuid = uuid
        self.title = title
        self.dateStartRaw = dateStartRaw
        self.dateEndRaw = dateEndRaw
        self.yearStart = yearStart
        self.yearEnd = yearEnd
        self.physicalForm = physicalForm
        self.division = division
        self.shelfLocator = shelfLocator
        self.frontImageID = frontImageID
        self.backImageID = backImageID
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.leftDetection = leftDetection
        self.rightDetection = rightDetection
    }
}

// MARK: - Computed Helpers

extension StereoCard {

    /// Human-readable date string for display.
    var displayDate: String? {
        switch (yearStart, yearEnd) {
        case let (start?, end?) where start == end:
            return "\(start)"
        case let (start?, end?):
            return "\(start)–\(end)"
        case let (start?, nil):
            return "\(start)"
        case let (nil, end?):
            return "–\(end)"
        case (nil, nil):
            return nil
        }
    }

    /// Extracts the leading 4-digit year from a raw date string like "1871-08" or "1850".
    static func parseYear(from rawDate: String?) -> Int? {
        guard let raw = rawDate, raw.count >= 4 else { return nil }
        let yearString = String(raw.prefix(4))
        return Int(yearString)
    }

    // MARK: - Image URLs

    /// Base URL for NYPL IIIF image server.
    private static let iiifBase = "https://iiif-prod.nypl.org/index.php"

    /// Returns the IIIF URL for the front of the card at the given quality.
    ///
    /// Quality codes:
    /// - `b` — .jpeg center cropped thumbnail (100×100 pixels)
    /// - `f` — .jpeg (140 pixels tall, variable width)
    /// - `t` — .gif (150 pixels on the long side)
    /// - `r` — .jpeg (300 pixels on the long side)
    /// - `w` — .jpeg (760 pixels on the long side)
    /// - `q` — .jpeg (1600 pixels on the long side)
    /// - `v` — .jpeg (2560 pixels on the long side)
    /// - `g` — .jpeg original dimensions
    func frontImageURL(quality: String = "w") -> URL? {
        guard let id = frontImageID else { return nil }
        return URL(string: "\(Self.iiifBase)?id=\(id)&t=\(quality)")
    }

    /// Returns the IIIF URL for the back of the card at the given quality.
    func backImageURL(quality: String = "w") -> URL? {
        guard let id = backImageID else { return nil }
        return URL(string: "\(Self.iiifBase)?id=\(id)&t=\(quality)")
    }
}
