//
//  CardGridView.swift
//  Stereologue
//
//  Reusable adaptive grid of stereoview cards with navigation links.
//

import SwiftUI
import SwiftData
import Nuke

struct CardGridView: View {
    let cards: [StereoCard]
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String

    @Environment(CardListContext.self) private var cardListContext
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .diskCache
    )

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    init(
        cards: [StereoCard],
        emptyTitle: String = "No Cards",
        emptySystemImage: String = "photo.on.rectangle.angled",
        emptyDescription: String = "No cards to display."
    ) {
        self.cards = cards
        self.emptyTitle = emptyTitle
        self.emptySystemImage = emptySystemImage
        self.emptyDescription = emptyDescription
    }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView(
                    emptyTitle,
                    systemImage: emptySystemImage,
                    description: Text(emptyDescription)
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(cards, id: \.uuid) { card in
                            NavigationLink(value: card) {
                                CardGridItemView(card: card)
                                    .onAppear { prefetchAround(card) }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .onAppear { cardListContext.cards = cards }
        .onChange(of: cards.count) { cardListContext.cards = cards }
        .onDisappear { prefetcher.stopPrefetching() }
    }

    private func prefetchAround(_ card: StereoCard) {
        guard let index = cards.firstIndex(where: { $0.uuid == card.uuid }) else { return }
        // Prefetch the next 10 cards ahead
        let prefetchRange = (index + 1)..<min(index + 11, cards.count)
        let urls = cards[prefetchRange].compactMap { $0.frontImageURL(quality: "r") }
        prefetcher.startPrefetching(with: urls)
    }
}

#if DEBUG
#Preview("With Cards", traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CardGridView(cards: PreviewSampleData.sampleCards)
    }
    .previewEnvironment()
}

#Preview("Empty State", traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        CardGridView(
            cards: [],
            emptyTitle: "No Cards",
            emptySystemImage: "photo.on.rectangle.angled",
            emptyDescription: "No cards to display."
        )
    }
}
#endif
