//
//  CatalogStoreMigrationTests.swift
//  StereologueTests
//
//  Run this test to migrate the v1 CatalogStore.store (string collections)
//  to v2 (Collection model relationships). The new store is written to
//  the project directory so you can replace the bundled store.
//

import Testing
import Foundation
import SwiftData
@testable import Stereologue

struct CatalogStoreMigrationTests {

    /// Migrates the bundled v1 store to v2 with Collection model objects.
    /// The new store is saved next to the old one as "CatalogStore_v2.store".
    ///
    /// After running, copy the output file over the bundled CatalogStore.store:
    ///   cp CatalogStore_v2.store Stereologue/CatalogStore.store
    @Test func migrateCatalogStoreToV2() async throws {
        // Find the old bundled store in the app bundle
        let oldStoreURL = Bundle.main.url(forResource: "CatalogStore", withExtension: "store")
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // StereologueTests/
                .deletingLastPathComponent()  // Stereologue/ (project root)
                .appendingPathComponent("Stereologue")
                .appendingPathComponent("CatalogStore.store")

        #expect(FileManager.default.fileExists(atPath: oldStoreURL.path),
                "Old CatalogStore.store not found at \(oldStoreURL.path)")

        // Write new store to a temp location
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StereologueMigration", isDirectory: true)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let newStoreURL = outputDir.appendingPathComponent("CatalogStore_v2.store")

        // Run migration
        _ = try await MainActor.run {
            try CatalogStoreMigrator.migrate(from: oldStoreURL, to: newStoreURL)
        }

        // Verify the new store
        let schema = Schema([
            StereoCard.self,
            Creator.self,
            Subject.self,
            Place.self,
            Collection.self,
        ])
        let config = ModelConfiguration(
            "VerifyStore",
            schema: schema,
            url: newStoreURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: config)

        try await MainActor.run {
            let context = container.mainContext

            let cardCount = try context.fetchCount(FetchDescriptor<StereoCard>())
            let creatorCount = try context.fetchCount(FetchDescriptor<Creator>())
            let subjectCount = try context.fetchCount(FetchDescriptor<Subject>())
            let placeCount = try context.fetchCount(FetchDescriptor<Place>())
            let collectionCount = try context.fetchCount(FetchDescriptor<Collection>())

            print("=== Migration Results ===")
            print("Cards:       \(cardCount)")
            print("Creators:    \(creatorCount)")
            print("Subjects:    \(subjectCount)")
            print("Places:      \(placeCount)")
            print("Collections: \(collectionCount)")
            print("New store:   \(newStoreURL.path)")
            print("=========================")

            // Verify counts match expectations
            #expect(cardCount > 40000, "Expected ~41K cards, got \(cardCount)")
            #expect(creatorCount > 1700, "Expected ~1744 creators, got \(creatorCount)")
            #expect(subjectCount > 1700, "Expected ~1789 subjects, got \(subjectCount)")
            #expect(placeCount > 1300, "Expected ~1350 places, got \(placeCount)")
            #expect(collectionCount > 0, "Expected collections to be created")

            // Verify a card has a collection relationship
            var descriptor = FetchDescriptor<StereoCard>(
                predicate: #Predicate { $0.collection != nil }
            )
            descriptor.fetchLimit = 1
            let cardsWithCollection = try context.fetch(descriptor)
            #expect(!cardsWithCollection.isEmpty, "No cards have a collection relationship")

            if let card = cardsWithCollection.first {
                print("Sample card: \(card.title)")
                print("  Collection: \(card.collection?.name ?? "nil")")
                print("  Creator: \(card.creator?.name ?? "nil")")
            }
        }

        print("\nTo replace the bundled store, run:")
        print("  cp \"\(newStoreURL.path)\" \"\(oldStoreURL.path)\"")
    }
}
