//
//  CatalogStoreMigrator.swift
//  Stereologue
//
//  Reads the v1 CatalogStore.store (where collection was a String on StereoCard)
//  and writes a new v2 store through SwiftData APIs, ensuring all metadata is correct.
//
//  Usage: Call CatalogStoreMigrator.migrate(from:to:) from a test or script.
//

import Foundation
import SwiftData
import OSLog
import SQLite3

@MainActor
final class CatalogStoreMigrator {

    private let logger = Logger(subsystem: "net.atompowered.Stereologue", category: "Migrator")

    // Caches keyed by old Z_PK to avoid duplicate inserts
    private var creatorsByPK: [Int64: Creator] = [:]
    private var subjectsByPK: [Int64: Subject] = [:]
    private var placesByPK: [Int64: Place] = [:]
    private var collectionsByName: [String: Collection] = [:]

    // MARK: - Public API

    /// Migrates from old v1 store to a new v2 store at the given URL.
    /// Returns the URL of the new store.
    @discardableResult
    static func migrate(
        from oldStoreURL: URL,
        to newStoreURL: URL
    ) throws -> URL {
        let migrator = CatalogStoreMigrator()
        try migrator.run(oldStoreURL: oldStoreURL, newStoreURL: newStoreURL)
        return newStoreURL
    }

    // MARK: - Migration

    private func run(oldStoreURL: URL, newStoreURL: URL) throws {
        logger.info("Opening old store at \(oldStoreURL.path)")

        // Open old store read-only via SQLite3
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(oldStoreURL.path, &db, flags, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw MigrationError.cannotOpenOldStore(msg)
        }
        defer { sqlite3_close(db) }

        // Remove existing new store if present
        for ext in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(atPath: newStoreURL.path + ext)
        }

        // Create new SwiftData container
        let schema = Schema([
            StereoCard.self,
            Creator.self,
            Subject.self,
            Place.self,
            Collection.self,
        ])
        let config = ModelConfiguration(
            "CatalogStore",
            schema: schema,
            url: newStoreURL,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: config)
        let context = container.mainContext
        context.autosaveEnabled = false

        // Step 1: Migrate Creators
        logger.info("Migrating creators...")
        try migrateCreators(db: db!, context: context)
        logger.info("Creators: \(self.creatorsByPK.count)")

        // Step 2: Migrate Subjects
        logger.info("Migrating subjects...")
        try migrateSubjects(db: db!, context: context)
        logger.info("Subjects: \(self.subjectsByPK.count)")

        // Step 3: Migrate Places
        logger.info("Migrating places...")
        try migratePlaces(db: db!, context: context)
        logger.info("Places: \(self.placesByPK.count)")

        // Step 4: Read join tables into memory
        logger.info("Reading join tables...")
        let cardPlaces = try readJoinTable(db: db!, table: "Z_2CARDS", leftCol: "Z_3CARDS", rightCol: "Z_2PLACES")
        let cardSubjects = try readJoinTable(db: db!, table: "Z_3SUBJECTS", leftCol: "Z_3CARDS1", rightCol: "Z_4SUBJECTS")

        // Step 5: Migrate StereoCards (creates Collection objects as needed)
        logger.info("Migrating stereo cards...")
        let cardCount = try migrateStereoCards(
            db: db!,
            context: context,
            cardPlaces: cardPlaces,
            cardSubjects: cardSubjects
        )
        logger.info("Cards: \(cardCount), Collections: \(self.collectionsByName.count)")

        // Step 6: Save
        logger.info("Saving new store...")
        try context.save()
        logger.info("Migration complete! New store at \(newStoreURL.path)")
    }

    // MARK: - Creators

    private func migrateCreators(db: OpaquePointer, context: ModelContext) throws {
        let sql = "SELECT Z_PK, ZNAME FROM ZCREATOR"
        try query(db: db, sql: sql) { stmt in
            let pk = sqlite3_column_int64(stmt, 0)
            let name = columnText(stmt, 1) ?? ""
            let creator = Creator(name: name)
            context.insert(creator)
            creatorsByPK[pk] = creator
        }
    }

    // MARK: - Subjects

    private func migrateSubjects(db: OpaquePointer, context: ModelContext) throws {
        let sql = "SELECT Z_PK, ZNAME FROM ZSUBJECT"
        try query(db: db, sql: sql) { stmt in
            let pk = sqlite3_column_int64(stmt, 0)
            let name = columnText(stmt, 1) ?? ""
            let subject = Subject(name: name)
            context.insert(subject)
            subjectsByPK[pk] = subject
        }
    }

    // MARK: - Places

    private func migratePlaces(db: OpaquePointer, context: ModelContext) throws {
        let sql = "SELECT Z_PK, ZNAME FROM ZPLACE"
        try query(db: db, sql: sql) { stmt in
            let pk = sqlite3_column_int64(stmt, 0)
            let name = columnText(stmt, 1) ?? ""
            let place = Place(name: name)
            context.insert(place)
            placesByPK[pk] = place
        }
    }

    // MARK: - Join Tables

    /// Returns a dictionary: cardPK -> [relatedEntityPK]
    private func readJoinTable(
        db: OpaquePointer,
        table: String,
        leftCol: String,
        rightCol: String
    ) throws -> [Int64: [Int64]] {
        var result: [Int64: [Int64]] = [:]
        let sql = "SELECT \(leftCol), \(rightCol) FROM \(table)"
        try query(db: db, sql: sql) { stmt in
            let cardPK = sqlite3_column_int64(stmt, 0)
            let relatedPK = sqlite3_column_int64(stmt, 1)
            result[cardPK, default: []].append(relatedPK)
        }
        return result
    }

    // MARK: - StereoCards

    private func migrateStereoCards(
        db: OpaquePointer,
        context: ModelContext,
        cardPlaces: [Int64: [Int64]],
        cardSubjects: [Int64: [Int64]]
    ) throws -> Int {
        let sql = """
            SELECT Z_PK, ZUUID, ZTITLE, ZDATESTARTRAW, ZDATEENDRAW,
                   ZYEARSTART, ZYEAREND, ZPHYSICALFORM, ZDIVISION,
                   ZCOLLECTION, ZSHELFLOCATOR, ZCREATOR,
                   ZFRONTIMAGEID, ZBACKIMAGEID,
                   ZIMAGEWIDTH, ZIMAGEHEIGHT,
                   ZDETECTIONID, ZCLASSIFICATION, ZCONFIDENCE, ZX, ZY, ZWIDTH, ZHEIGHT,
                   ZDETECTIONID1, ZCLASSIFICATION1, ZCONFIDENCE1, ZX1, ZY1, ZWIDTH1, ZHEIGHT1
            FROM ZSTEREOCARD
            """
        var count = 0

        try query(db: db, sql: sql) { stmt in
            let pk = sqlite3_column_int64(stmt, 0)
            let uuid = columnText(stmt, 1) ?? ""
            let title = columnText(stmt, 2) ?? ""
            let dateStartRaw = columnText(stmt, 3)
            let dateEndRaw = columnText(stmt, 4)
            let yearStart = columnIntOrNil(stmt, 5)
            let yearEnd = columnIntOrNil(stmt, 6)
            let physicalForm = columnText(stmt, 7)
            let division = columnText(stmt, 8)
            let collectionName = columnText(stmt, 9)
            let shelfLocator = columnText(stmt, 10)
            let creatorPK = columnInt64OrNil(stmt, 11)
            let frontImageID = columnText(stmt, 12)
            let backImageID = columnText(stmt, 13)
            let imageWidth = columnDoubleOrNil(stmt, 14)
            let imageHeight = columnDoubleOrNil(stmt, 15)

            let leftDetection = ImageDetection(
                detectionID: columnText(stmt, 16) ?? "",
                classification: columnText(stmt, 17) ?? "",
                confidence: sqlite3_column_double(stmt, 18),
                x: sqlite3_column_double(stmt, 19),
                y: sqlite3_column_double(stmt, 20),
                width: sqlite3_column_double(stmt, 21),
                height: sqlite3_column_double(stmt, 22)
            )
            let rightDetection = ImageDetection(
                detectionID: columnText(stmt, 23) ?? "",
                classification: columnText(stmt, 24) ?? "",
                confidence: sqlite3_column_double(stmt, 25),
                x: sqlite3_column_double(stmt, 26),
                y: sqlite3_column_double(stmt, 27),
                width: sqlite3_column_double(stmt, 28),
                height: sqlite3_column_double(stmt, 29)
            )

            let card = StereoCard(
                uuid: uuid,
                title: title,
                dateStartRaw: dateStartRaw,
                dateEndRaw: dateEndRaw,
                yearStart: yearStart,
                yearEnd: yearEnd,
                physicalForm: physicalForm,
                division: division,
                shelfLocator: shelfLocator,
                frontImageID: frontImageID,
                backImageID: backImageID,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                leftDetection: leftDetection,
                rightDetection: rightDetection
            )

            // Creator (one-to-many)
            if let cpk = creatorPK {
                card.creator = creatorsByPK[cpk]
            }

            // Subjects (many-to-many)
            if let subjectPKs = cardSubjects[pk] {
                card.subjects = subjectPKs.compactMap { subjectsByPK[$0] }
            }

            // Places (many-to-many)
            if let placePKs = cardPlaces[pk] {
                card.places = placePKs.compactMap { placesByPK[$0] }
            }

            // Collection (new relationship - was a String, now a Collection model)
            if let name = collectionName {
                if let existing = collectionsByName[name] {
                    card.collection = existing
                } else {
                    let collection = Collection(name: name)
                    context.insert(collection)
                    collectionsByName[name] = collection
                    card.collection = collection
                }
            }

            context.insert(card)
            count += 1

            if count % 5000 == 0 {
                logger.info("Processed \(count) cards...")
            }
        }

        return count
    }

    // MARK: - SQLite Helpers

    private func query(
        db: OpaquePointer,
        sql: String,
        row: (OpaquePointer) -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw MigrationError.sqlError(msg)
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt!)
        }
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        guard let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    private func columnIntOrNil(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private func columnInt64OrNil(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    private func columnDoubleOrNil(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }
}

// MARK: - Errors

enum MigrationError: LocalizedError {
    case cannotOpenOldStore(String)
    case sqlError(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenOldStore(let msg): return "Cannot open old store: \(msg)"
        case .sqlError(let msg): return "SQL error: \(msg)"
        }
    }
}
