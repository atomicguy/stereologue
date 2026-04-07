//
//  CardGridView.swift
//  Stereologue
//
//  Reusable adaptive grid of stereoview cards with navigation links.
//

import SwiftUI
import SwiftData

struct CardGridView: View {
    let cards: [StereoCard]
    let emptyTitle: String
    let emptySystemImage: String
    let emptyDescription: String

    @Environment(CardListContext.self) private var cardListContext

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
