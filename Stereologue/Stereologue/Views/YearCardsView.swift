//
//  YearCardsView.swift
//  Stereologue
//
//  Grid of cards filtered to a specific year.
//

import SwiftUI
import SwiftData

struct YearCardsView: View {
    let year: Int
    @Query private var cards: [StereoCard]

    init(year: Int) {
        self.year = year
        _cards = Query(
            filter: #Predicate<StereoCard> { card in
                card.yearStart == year
            },
            sort: \StereoCard.title
        )
    }

    var body: some View {
        CardGridView(
            cards: cards,
            emptyTitle: "No Cards",
            emptySystemImage: "calendar",
            emptyDescription: "No cards from \(year)."
        )
        .navigationTitle(String(year))
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        YearCardsView(year: 1901)
    }
    .previewEnvironment()
}
#endif
