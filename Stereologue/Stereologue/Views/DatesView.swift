//
//  DatesView.swift
//  Stereologue
//
//  Browse cards grouped by decade and year.
//

import SwiftUI
import SwiftData

struct DatesView: View {
    @Query(sort: \StereoCard.yearStart) private var allCards: [StereoCard]

    private var decades: [(decade: Int, years: [(year: Int, count: Int)])] {
        let dated = allCards.filter { $0.yearStart != nil }
        let byDecade = Dictionary(grouping: dated) { ($0.yearStart! / 10) * 10 }

        return byDecade.keys.sorted().map { decade in
            let decadeCards = byDecade[decade]!
            let byYear = Dictionary(grouping: decadeCards) { $0.yearStart! }
            let years = byYear.keys.sorted().map { year in
                (year: year, count: byYear[year]!.count)
            }
            return (decade: decade, years: years)
        }
    }

    var body: some View {
        List {
            ForEach(decades, id: \.decade) { decadeGroup in
                Section("\(decadeGroup.decade)s") {
                    ForEach(decadeGroup.years, id: \.year) { yearGroup in
                        NavigationLink(value: YearSelection(year: yearGroup.year)) {
                            HStack {
                                Text(String(yearGroup.year))
                                    .font(.headline)
                                Spacer()
                                Text("^[\(yearGroup.count) card](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Dates")
    }
}

/// Lightweight navigation value wrapping a year.
struct YearSelection: Hashable {
    let year: Int
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 400, height: 700)) {
    NavigationStack {
        DatesView()
    }
    .previewEnvironment()
}
#endif
