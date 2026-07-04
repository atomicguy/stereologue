//
//  UserCropOverride.swift
//  Stereologue
//
//  User-edited crop bounding boxes that override ML-detected values.
//  Stored in the User store (CloudKit-synced). References card by UUID string.
//

import Foundation
import SwiftData

@Model
final class UserCropOverride {

    // No `#Unique` on `cardUUID`: CloudKit-backed stores reject unique
    // constraints, and this model is CloudKit-ready. Uniqueness is enforced in
    // code — `UserDataService.saveCropOverride` upserts, and `cropOverride(for:)`
    // reconciles any duplicates a sync merge might introduce.
    var id: UUID = UUID()
    var cardUUID: String = ""
    var leftDetection: ImageDetection = ImageDetection()
    var rightDetection: ImageDetection = ImageDetection()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        cardUUID: String,
        leftDetection: ImageDetection,
        rightDetection: ImageDetection
    ) {
        self.id = UUID()
        self.cardUUID = cardUUID
        self.leftDetection = leftDetection
        self.rightDetection = rightDetection
        self.createdAt = .now
        self.updatedAt = .now
    }
}
