//
//  RestorationEvalSet.swift
//  Stereologue
//
//  The fixed set of cards every restoration change is judged against.
//

import Foundation

/// One card in the evaluation set and why it's there.
nonisolated struct RestorationEvalCard: Codable, Hashable, Identifiable, Sendable {
    let uuid: String
    let frontImageID: String?
    let title: String
    /// One of the `RestorationEvalSet.categories`.
    let category: String
    /// The measured statistic that put it in its category.
    let note: String

    var id: String { uuid }
}

/// Loaded from `Fixtures/restoration-eval.json` in the app bundle.
///
/// The cards were auto-selected by per-eye image statistics (see the file's
/// `method`), so a category is a strong hint, not ground truth. Confirm each
/// card visually in the Restoration Eval tool before relying on it.
nonisolated struct RestorationEvalSet: Codable, Sendable {
    let version: Int
    let generated: String
    let method: String
    let cards: [RestorationEvalCard]

    /// Display order of categories.
    static let categories = [
        "clean", "defects", "blown", "dark", "faded",
        "uneven", "mismatch", "sepia", "tinted",
    ]

    static func load(from bundle: Bundle = .main) throws -> RestorationEvalSet {
        guard let url = bundle.url(forResource: "restoration-eval", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(RestorationEvalSet.self, from: Data(contentsOf: url))
    }

    var byCategory: [(category: String, cards: [RestorationEvalCard])] {
        Self.categories.compactMap { category in
            let matching = cards.filter { $0.category == category }
            return matching.isEmpty ? nil : (category, matching)
        }
    }
}
