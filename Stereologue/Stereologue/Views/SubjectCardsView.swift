//
//  SubjectCardsView.swift
//  Stereologue
//
//  Grid of cards for a given subject.
//

import SwiftUI

struct SubjectCardsView: View {
    let subject: Subject

    var body: some View {
        PagedCardGridView(
            predicate: predicate,
            emptyTitle: "No Cards",
            emptySystemImage: "tag",
            emptyDescription: "No cards for this subject."
        )
        .navigationTitle(subject.name)
    }

    private var predicate: Predicate<StereoCard> {
        let name = subject.name
        return #Predicate<StereoCard> { card in
            card.subjects.contains { $0.name == name }
        }
    }
}

#if DEBUG
#Preview(traits: .fixedLayout(width: 900, height: 700)) {
    NavigationStack {
        SubjectCardsView(subject: PreviewSampleData.sampleSubject)
    }
    .previewEnvironment()
}
#endif
