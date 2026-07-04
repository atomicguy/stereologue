//
//  DatesView.swift
//  Stereologue
//
//  Browse cards grouped by decade and year.
//

import SwiftUI
import SwiftData

struct DatesView: View {
    @Environment(\.modelContext) private var catalogContext
    @State private var decades: [DecadeGroup] = []

    var body: some View {
        List {
            ForEach(decades) { decadeGroup in
                Section("\(decadeGroup.decade)s") {
                    ForEach(decadeGroup.years) { yearGroup in
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
        .task { loadDecades() }
    }

    /// Fetches just the `yearStart` column (the catalog is read-only, so a
    /// one-shot fetch is fine) and groups it into decades once, rather than
    /// materializing all 41K cards and re-grouping on every body pass.
    private func loadDecades() {
        guard decades.isEmpty else { return }
        var descriptor = FetchDescriptor<StereoCard>(
            predicate: #Predicate { $0.yearStart != nil },
            sortBy: [SortDescriptor(\.yearStart)]
        )
        descriptor.propertiesToFetch = [\.yearStart]
        let years = (try? catalogContext.fetch(descriptor))?.compactMap(\.yearStart) ?? []

        let byDecade = Dictionary(grouping: years) { ($0 / 10) * 10 }
        decades = byDecade.keys.sorted().map { decade in
            let byYear = Dictionary(grouping: byDecade[decade]!) { $0 }
            let yearCounts = byYear.keys.sorted().map { year in
                YearCount(year: year, count: byYear[year]!.count)
            }
            return DecadeGroup(decade: decade, years: yearCounts)
        }
    }
}

/// A decade and the per-year card counts within it.
private struct DecadeGroup: Identifiable {
    let decade: Int
    let years: [YearCount]
    var id: Int { decade }
}

/// A single year and how many cards fall in it.
private struct YearCount: Identifiable {
    let year: Int
    let count: Int
    var id: Int { year }
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
