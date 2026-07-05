//
//  DatesView.swift
//  Stereologue
//
//  Browse cards by year, as a grid of mosaic thumbnails matching the other
//  browse tabs (Subjects/Creators/Places/Collections).
//

import SwiftUI
import SwiftData

struct DatesView: View {
    @Environment(\.catalogQueryService) private var queryService
    @State private var years: [YearGroup] = []

    var body: some View {
        BrowseMosaicGrid(
            entities: years,
            id: \.id,
            title: { String($0.year) },
            count: \.count,
            predicate: { group in
                let year = group.year
                return #Predicate { $0.yearStart == year }
            }
        )
        .navigationTitle("Dates")
        .task { await loadYears() }
    }

    /// Loads the per-year counts once, off the main actor via
    /// `CatalogQueryService`, so the large `yearStart` scan doesn't hitch the UI.
    private func loadYears() async {
        guard years.isEmpty, let queryService else { return }
        years = await queryService.yearCounts()
    }
}

/// A single year and its card count. Doubles as the browse-grid entity and the
/// navigation value for `YearCardsView`. `nonisolated` (the project defaults to
/// MainActor) so it's Sendable across the `CatalogQueryService` actor boundary.
nonisolated struct YearGroup: Hashable, Identifiable, Sendable {
    let year: Int
    let count: Int
    var id: String { String(year) }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        DatesView()
    }
    .previewEnvironment()
}
#endif
