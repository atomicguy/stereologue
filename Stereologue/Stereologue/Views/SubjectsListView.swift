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

    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(subjects, id: \.name) { subject in
                    let name = subject.name
                    NavigationLink(value: subject) {
                        BrowseMosaicItem(
                            title: name,
                            cardPredicate: #Predicate { card in
                                card.subjects.contains { $0.name == name }
                            }
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
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
