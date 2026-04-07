//
//  ContentView.swift
//  Stereologue
//
//  Root view using TabView with sidebarAdaptable style.
//  iPadOS: top tab bar that adapts into a sidebar.
//  macOS: always shows a sidebar.
//  visionOS: ornament + sidebar for TabSection tabs.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(UserDataService.self) private var userDataService
    @Environment(\.modelContext) private var catalogContext

    @State private var selectedTab: AppTab = .library
    @State private var albums: [UserAlbum] = []
    @State private var cardListContext = CardListContext()

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - Library
            Tab("Library", systemImage: "photo.on.rectangle.angled", value: AppTab.library) {
                NavigationStack {
                    LibraryView()
                        .cardNavigationDestinations()
                }
            }

            // MARK: - Favorites
            Tab("Favorites", systemImage: "heart.fill", value: AppTab.favorites) {
                NavigationStack {
                    FavoritesView()
                        .cardNavigationDestinations()
                }
            }

            // MARK: - Browse
            Tab("Dates", systemImage: "calendar", value: AppTab.dates) {
                NavigationStack {
                    DatesView()
                        .navigationDestination(for: YearSelection.self) { selection in
                            YearCardsView(year: selection.year)
                        }
                        .cardNavigationDestinations()
                }
            }

            Tab("Subjects", systemImage: "tag", value: AppTab.subjects) {
                NavigationStack {
                    SubjectsListView()
                        .cardNavigationDestinations()
                }
            }

            Tab("Creators", systemImage: "person.2", value: AppTab.creators) {
                NavigationStack {
                    CreatorsListView()
                        .cardNavigationDestinations()
                }
            }

            Tab("Places", systemImage: "mappin.and.ellipse", value: AppTab.places) {
                NavigationStack {
                    PlacesListView()
                        .cardNavigationDestinations()
                }
            }

            Tab("Collections", systemImage: "building.columns", value: AppTab.collections) {
                NavigationStack {
                    CollectionsListView()
                        .cardNavigationDestinations()
                }
            }

            // MARK: - Albums
            TabSection("Albums") {
                ForEach(albums, id: \.id) { album in
                    Tab(album.name, systemImage: "rectangle.stack", value: AppTab.album(album.id)) {
                        NavigationStack {
                            AlbumDetailView(album: album)
                                .cardNavigationDestinations()
                        }
                    }
                }
            }
            .defaultVisibility(.hidden, for: .tabBar)
            .sectionActions {
                Button("New Album", systemImage: "plus") {
                    _ = userDataService.createAlbum(name: "New Album")
                    refreshAlbums()
                }
            }

        }
        .tabViewStyle(.sidebarAdaptable)
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .fontDesign(.serif)
        .environment(cardListContext)
        .onAppear { refreshAlbums() }
    }

    private func refreshAlbums() {
        albums = userDataService.allAlbums()
    }
}

// MARK: - Shared Navigation Destinations

extension View {
    /// Registers all navigation destinations needed for browsing the catalog.
    /// Apply once at the NavigationStack root so links work at any depth.
    func cardNavigationDestinations() -> some View {
        self
            .navigationDestination(for: StereoCard.self) { card in
                CardPagerView(initialCard: card)
            }
            .navigationDestination(for: Subject.self) { subject in
                SubjectCardsView(subject: subject)
            }
            .navigationDestination(for: Creator.self) { creator in
                CreatorCardsView(creator: creator)
            }
            .navigationDestination(for: Place.self) { place in
                PlaceCardsView(place: place)
            }
            .navigationDestination(for: CollectionDestination.self) { destination in
                CollectionCardsView(collectionName: destination.name)
            }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 1100, height: 800)) {
    ContentView()
        .previewEnvironment()
}
#endif
