//
//  PreviewSampleData.swift
//  Stereologue
//
//  In-memory SwiftData containers and sample data for Xcode previews.
//

#if DEBUG

import SwiftData
import SwiftUI

@MainActor
enum PreviewSampleData {

    // MARK: - Catalog Container (In-Memory)

    static let container: ModelContainer = {
        let schema = Schema([
            StereoCard.self,
            Creator.self,
            Subject.self,
            Place.self,
            Collection.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("PreviewSampleData: failed to build in-memory catalog container — \(error)")
        }
        let context = container.mainContext

        // Creators
        let keystone = Creator(name: "Keystone View Company")
        let underwood = Creator(name: "Underwood & Underwood")
        let kilburn = Creator(name: "B. W. Kilburn")
        context.insert(keystone)
        context.insert(underwood)
        context.insert(kilburn)

        // Subjects
        let architecture = Subject(name: "Architecture")
        let landscapes = Subject(name: "Landscapes")
        let bridges = Subject(name: "Bridges")
        let waterfalls = Subject(name: "Waterfalls")
        let people = Subject(name: "People")
        let monuments = Subject(name: "Monuments")
        for s in [architecture, landscapes, bridges, waterfalls, people, monuments] {
            context.insert(s)
        }

        // Places
        let newYork = Place(name: "New York, N.Y.")
        let paris = Place(name: "Paris, France")
        let niagara = Place(name: "Niagara Falls, N.Y.")
        let washington = Place(name: "Washington, D.C.")
        let yosemite = Place(name: "Yosemite Valley, Cal.")
        for p in [newYork, paris, niagara, washington, yosemite] {
            context.insert(p)
        }

        // Collections
        let dennisCollection = Collection(name: "Robert N. Dennis Collection")
        let stereoCollection = Collection(name: "Stereograph Collection")
        context.insert(dennisCollection)
        context.insert(stereoCollection)

        // Sample cards
        let cardData: [(String, String, Int?, Creator?, [Subject], [Place], Collection)] = [
            ("preview-001", "Brooklyn Bridge from Manhattan side, New York", 1901, keystone, [architecture, bridges], [newYork], dennisCollection),
            ("preview-002", "Eiffel Tower from the Trocadero, Paris Exposition", 1889, underwood, [architecture, monuments], [paris], dennisCollection),
            ("preview-003", "Niagara Falls from Prospect Point", 1905, keystone, [landscapes, waterfalls], [niagara], stereoCollection),
            ("preview-004", "The Capitol Building, Washington", 1898, underwood, [architecture, monuments], [washington], dennisCollection),
            ("preview-005", "Yosemite Falls from the Valley Floor", 1870, kilburn, [landscapes, waterfalls], [yosemite], stereoCollection),
            ("preview-006", "Central Park, looking north from the terrace", 1895, keystone, [landscapes, people], [newYork], dennisCollection),
            ("preview-007", "Arc de Triomphe, Paris", 1900, underwood, [architecture, monuments], [paris], dennisCollection),
            ("preview-008", "Suspension Bridge over the Niagara River", 1885, kilburn, [bridges, landscapes], [niagara], stereoCollection),
            ("preview-009", "Washington Monument from the Mall", 1893, underwood, [monuments], [washington], dennisCollection),
            ("preview-010", "El Capitan and Bridal Veil Fall, Yosemite", 1872, kilburn, [landscapes, waterfalls], [yosemite], stereoCollection),
        ]

        for (uuid, title, year, creator, subjects, places, collection) in cardData {
            let card = StereoCard(
                uuid: uuid,
                title: title,
                yearStart: year,
                yearEnd: year,
                frontImageID: "G91F069_\(uuid.suffix(3))ZF"
            )
            card.creator = creator
            card.subjects = subjects
            card.places = places
            card.collection = collection
            context.insert(card)
        }

        return container
    }()

    // MARK: - User Container (In-Memory)

    static let userContainer: ModelContainer = {
        let schema = Schema([
            UserAlbum.self,
            UserAlbumEntry.self,
            UserFavorite.self,
            UserNote.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("PreviewSampleData: failed to build in-memory user container — \(error)")
        }
    }()

    static let userDataService: UserDataService = {
        UserDataService(userContext: userContainer.mainContext)
    }()

    static let catalogQueryService = CatalogQueryService(modelContainer: container)

    // MARK: - Sample Object Accessors

    private static func firstSample<T: PersistentModel>(_ type: T.Type) -> T {
        do {
            guard let first = try container.mainContext.fetch(FetchDescriptor<T>()).first else {
                fatalError("PreviewSampleData: no \(type) seeded — sample data setup is broken")
            }
            return first
        } catch {
            fatalError("PreviewSampleData: failed to fetch \(type) — \(error)")
        }
    }

    static var sampleCard: StereoCard {
        firstSample(StereoCard.self)
    }

    static var sampleCards: [StereoCard] {
        do {
            return try container.mainContext.fetch(FetchDescriptor<StereoCard>())
        } catch {
            fatalError("PreviewSampleData: failed to fetch StereoCards — \(error)")
        }
    }

    static var sampleCreator: Creator {
        firstSample(Creator.self)
    }

    static var sampleSubject: Subject {
        firstSample(Subject.self)
    }

    static var samplePlace: Place {
        firstSample(Place.self)
    }

    static var sampleCollection: Collection {
        firstSample(Collection.self)
    }

    static var sampleAlbum: UserAlbum {
        let context = userContainer.mainContext
        let existing: [UserAlbum]
        do {
            existing = try context.fetch(FetchDescriptor<UserAlbum>())
        } catch {
            fatalError("PreviewSampleData: failed to fetch UserAlbums — \(error)")
        }
        if let album = existing.first { return album }
        let album = UserAlbum(name: "My Collection")
        context.insert(album)
        return album
    }
}

// MARK: - Preview Modifier

/// Convenience modifier that injects both containers and the user data service.
struct PreviewEnvironment: ViewModifier {
    @State private var cardListContext = CardListContext()

    func body(content: Content) -> some View {
        content
            .modelContainer(PreviewSampleData.container)
            .environment(\.userModelContext, PreviewSampleData.userContainer.mainContext)
            .environment(PreviewSampleData.userDataService)
            .environment(\.catalogQueryService, PreviewSampleData.catalogQueryService)
            .environment(cardListContext)
    }
}

extension View {
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironment())
    }
}

#endif
