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
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: config)
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

        // Sample cards
        let cardData: [(String, String, Int?, Creator?, [Subject], [Place])] = [
            ("preview-001", "Brooklyn Bridge from Manhattan side, New York", 1901, keystone, [architecture, bridges], [newYork]),
            ("preview-002", "Eiffel Tower from the Trocadero, Paris Exposition", 1889, underwood, [architecture, monuments], [paris]),
            ("preview-003", "Niagara Falls from Prospect Point", 1905, keystone, [landscapes, waterfalls], [niagara]),
            ("preview-004", "The Capitol Building, Washington", 1898, underwood, [architecture, monuments], [washington]),
            ("preview-005", "Yosemite Falls from the Valley Floor", 1870, kilburn, [landscapes, waterfalls], [yosemite]),
            ("preview-006", "Central Park, looking north from the terrace", 1895, keystone, [landscapes, people], [newYork]),
            ("preview-007", "Arc de Triomphe, Paris", 1900, underwood, [architecture, monuments], [paris]),
            ("preview-008", "Suspension Bridge over the Niagara River", 1885, kilburn, [bridges, landscapes], [niagara]),
            ("preview-009", "Washington Monument from the Mall", 1893, underwood, [monuments], [washington]),
            ("preview-010", "El Capitan and Bridal Veil Fall, Yosemite", 1872, kilburn, [landscapes, waterfalls], [yosemite]),
        ]

        for (uuid, title, year, creator, subjects, places) in cardData {
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
        return try! ModelContainer(for: schema, configurations: config)
    }()

    static let userDataService: UserDataService = {
        UserDataService(userContext: userContainer.mainContext)
    }()

    // MARK: - Sample Object Accessors

    static var sampleCard: StereoCard {
        try! container.mainContext.fetch(FetchDescriptor<StereoCard>()).first!
    }

    static var sampleCards: [StereoCard] {
        try! container.mainContext.fetch(FetchDescriptor<StereoCard>())
    }

    static var sampleCreator: Creator {
        try! container.mainContext.fetch(FetchDescriptor<Creator>()).first!
    }

    static var sampleSubject: Subject {
        try! container.mainContext.fetch(FetchDescriptor<Subject>()).first!
    }

    static var samplePlace: Place {
        try! container.mainContext.fetch(FetchDescriptor<Place>()).first!
    }

    static var sampleAlbum: UserAlbum {
        let context = userContainer.mainContext
        let albums = try! context.fetch(FetchDescriptor<UserAlbum>())
        if let album = albums.first { return album }
        let album = UserAlbum(name: "My Collection")
        context.insert(album)
        return album
    }
}

// MARK: - Preview Modifier

/// Convenience modifier that injects both containers and the user data service.
struct PreviewEnvironment: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modelContainer(PreviewSampleData.container)
            .environment(\.userModelContext, PreviewSampleData.userContainer.mainContext)
            .environment(PreviewSampleData.userDataService)
    }
}

extension View {
    func previewEnvironment() -> some View {
        modifier(PreviewEnvironment())
    }
}

#endif
