//
//  SubjectsListView.swift
//  Stereologue
//
//  Browse subjects in a grid with mosaic thumbnails.
//

import SwiftUI
import SwiftData

struct SubjectsListView: View {
    @Query(sort: \Subject.name) private var subjects: [Subject]

    var body: some View {
        BrowseMosaicGrid(
            entities: subjects,
            id: \.name,
            title: { $0.name },
            count: \.cardCount,
            predicate: { subject in
                let name = subject.name
                return #Predicate { card in
                    card.subjects.contains { $0.name == name }
                }
            }
        )
        .navigationTitle("Subjects")
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        SubjectsListView()
    }
    .previewEnvironment()
}
#endif
