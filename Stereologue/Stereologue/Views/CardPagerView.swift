//
//  CardPagerView.swift
//  Stereologue
//
//  Horizontally-paging wrapper around CardDetailView that lets the user
//  swipe left/right to browse adjacent cards from the originating grid.
//

import SwiftUI

struct CardPagerView: View {
    let initialCard: StereoCard
    @Environment(CardListContext.self) private var cardListContext
    @Environment(UserDataService.self) private var userDataService

    @State private var cards: [StereoCard]?
    @State private var currentCardUUID: String?
    @State private var isFavorite = false
    #if os(visionOS)
    @State private var showSpatialView = false
    private let spatialPhotoService = SpatialPhotoService()
    #endif

    init(initialCard: StereoCard) {
        self.initialCard = initialCard
        _currentCardUUID = State(initialValue: initialCard.uuid)
    }

    private var displayCards: [StereoCard] {
        cards ?? [initialCard]
    }

    private var currentCard: StereoCard {
        displayCards.first(where: { $0.uuid == currentCardUUID }) ?? initialCard
    }

    #if os(visionOS)
    private var stereoCards: [StereoCard] {
        displayCards.filter(\.hasStereoDetections)
    }
    #endif

    var body: some View {
        #if os(visionOS)
        if showSpatialView {
            SpatialPhotoView(
                cards: stereoCards,
                initialCardUUID: currentCard.uuid,
                spatialPhotoService: spatialPhotoService
            ) {
                showSpatialView = false
            }
        } else {
            cardContent
        }
        #else
        cardContent
        #endif
    }

    // MARK: - Card Pager Content

    @ViewBuilder
    private var cardContent: some View {
        if displayCards.count > 1 {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(displayCards, id: \.uuid) { card in
                        CardDetailView(card: card)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentCardUUID)
            .navigationTitle("")
            .toolbar { cardToolbar(for: currentCard) }
            .onChange(of: currentCardUUID) {
                isFavorite = userDataService.isFavorite(cardUUID: currentCard.uuid)
            }
            .onAppear {
                snapshotContextIfNeeded()
                isFavorite = userDataService.isFavorite(cardUUID: currentCard.uuid)
            }
        } else {
            CardDetailView(card: initialCard)
                .navigationTitle("")
                .toolbar { cardToolbar(for: initialCard) }
                .onAppear {
                    snapshotContextIfNeeded()
                    isFavorite = userDataService.isFavorite(cardUUID: initialCard.uuid)
                }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private func cardToolbar(for card: StereoCard) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                userDataService.toggleFavorite(cardUUID: card.uuid)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
            }
        }
        #if os(visionOS)
        ToolbarItem(placement: .secondaryAction) {
            Button {
                showSpatialView = true
            } label: {
                Label("View in Stereo", systemImage: "cube.transparent")
            }
            .disabled(!card.hasStereoDetections)
        }
        #endif
    }

    // MARK: - Helpers

    private func snapshotContextIfNeeded() {
        guard cards == nil else { return }
        let contextCards = cardListContext.cards
        if contextCards.contains(where: { $0.uuid == initialCard.uuid }) {
            cards = contextCards
        } else {
            cards = [initialCard]
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 700, height: 800)) {
    NavigationStack {
        CardPagerView(initialCard: PreviewSampleData.sampleCard)
    }
    .previewEnvironment()
    .environment(CardListContext())
}
#endif
