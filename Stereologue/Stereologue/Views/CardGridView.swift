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
    // Prefetch into the memory cache (the default) so cells appear instantly:
    // .diskCache would only download bytes and skip the expensive decode/resize.
    @State private var prefetcher = ImagePrefetcher(
        pipeline: .shared,
        destination: .memoryCache
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
        // Prefetch using the same request the cell renders, so the cache key
        // (URL + resize processor) matches and the work is reused on display.
        let requests = cards[prefetchRange].compactMap { CardGridItemView.thumbnailRequest(for: $0) }
        prefetcher.startPrefetching(with: requests)
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
