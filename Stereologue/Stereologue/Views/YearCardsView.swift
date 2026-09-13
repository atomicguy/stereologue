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

    var body: some View {
        PagedCardGridView(
            predicate: predicate,
            emptyTitle: "No Cards",
            emptySystemImage: "calendar",
            emptyDescription: "No cards from \(year)."
        )
        .navigationTitle(String(year))
    }

    private var predicate: Predicate<StereoCard> {
        let year = year
        return #Predicate<StereoCard> { $0.yearStart == year }
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
