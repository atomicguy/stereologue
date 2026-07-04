//
//  PlaceDuplicateFinder.swift
//  Stereologue
//
//  Offline curation tool: finds duplicate / variant place names in the
//  imported NYPL catalog so they can be merged to a single canonical form.
//
//  The NYPL place strings are largely in Library of Congress authority form
//  (`Pittsburgh (Pa.)`), but decades of contributors left variant spellings of
//  the same place — e.g. `New York, New York`, `New York City, New York`,
//  `New York, N.Y.`, `New York, NY`. This tool surfaces those.
//
//  Two complementary signals:
//
//  1. **Normalized key (high confidence).** A deterministic canonical key:
//     state abbreviations expanded (`N.Y.`/`NY` → "new york"), `City`/`NYC`
//     aliases resolved, punctuation stripped, components de-duplicated and
//     sorted so order doesn't matter. Names that collapse to the same key are
//     near-certain duplicates.
//
//  2. **Embedding similarity (review candidates).** Apple's `NLEmbedding`
//     sentence vectors catch fuzzier pairs the normalizer misses (nicknames,
//     reworded forms). These are *suggestions for human review*, because pure
//     semantics will happily rate `New York (N.Y.)` and `New York (State)` as
//     near-identical even though they are different places.
//
//  This is a build-time/dev tool, not shipped UI. Run it via a code snippet or
//  a debug command, review the output, and bake the merges into the rebuilt
//  `CatalogStore.store`.
//

import Foundation
import NaturalLanguage

// MARK: - Normalization

/// Produces canonical comparison keys for place-name strings.
enum PlaceNameNormalizer {

    /// Period-stripped, lowercased tokens → canonical full state name.
    /// Covers both LC/AACR2 abbreviations (`Calif.` → "calif") and USPS codes
    /// (`CA` → "ca"); both are keyed after stripping periods and lowercasing.
    static let stateExpansions: [String: String] = {
        // (full name, [LC abbrev w/o periods, USPS code])
        let states: [(String, [String])] = [
            ("alabama", ["ala", "al"]), ("alaska", ["alaska", "ak"]),
            ("arizona", ["ariz", "az"]), ("arkansas", ["ark", "ar"]),
            ("california", ["calif", "cal", "ca"]), ("colorado", ["colo", "col", "co"]),
            ("connecticut", ["conn", "ct"]), ("delaware", ["del", "de"]),
            ("district of columbia", ["dc"]),
            ("florida", ["fla", "fl"]), ("georgia", ["ga"]),
            ("hawaii", ["hawaii", "hi"]), ("idaho", ["idaho", "id"]),
            ("illinois", ["ill", "il"]), ("indiana", ["ind", "in"]),
            ("iowa", ["iowa", "ia"]), ("kansas", ["kan", "kans", "ks"]),
            ("kentucky", ["ky"]), ("louisiana", ["la"]),
            ("maine", ["maine", "me"]), ("maryland", ["md"]),
            ("massachusetts", ["mass", "ma"]), ("michigan", ["mich", "mi"]),
            ("minnesota", ["minn", "mn"]), ("mississippi", ["miss", "ms"]),
            ("missouri", ["mo"]), ("montana", ["mont", "mt"]),
            ("nebraska", ["neb", "nebr", "ne"]), ("nevada", ["nev", "nv"]),
            ("new hampshire", ["nh"]), ("new jersey", ["nj"]),
            ("new mexico", ["nmex", "nm"]), ("new york", ["ny"]),
            ("north carolina", ["nc"]), ("north dakota", ["ndak", "nd"]),
            ("ohio", ["ohio", "oh"]), ("oklahoma", ["okla", "ok"]),
            ("oregon", ["oreg", "ore", "or"]), ("pennsylvania", ["pa", "penn"]),
            ("rhode island", ["ri"]), ("south carolina", ["sc"]),
            ("south dakota", ["sdak", "sd"]), ("tennessee", ["tenn", "tn"]),
            ("texas", ["tex", "tx"]), ("utah", ["utah", "ut"]),
            ("vermont", ["vt"]), ("virginia", ["va"]),
            ("washington", ["wash", "wa"]), ("west virginia", ["wva", "wv"]),
            ("wisconsin", ["wis", "wisc", "wi"]), ("wyoming", ["wyo", "wy"]),
        ]
        var map: [String: String] = [:]
        for (full, abbrevs) in states {
            map[full] = full
            for abbrev in abbrevs { map[abbrev] = full }
        }
        return map
    }()

    /// Well-known full-token aliases for the same populated place. Extend as the
    /// curator discovers more. Kept separate from a general "drop the word City"
    /// rule, which would wrongly collapse Kansas City / Jersey City / etc.
    static let placeAliases: [String: String] = [
        "new york city": "new york",
        "nyc": "new york",
    ]

    /// A canonical, order-independent key. Names sharing a key are duplicates.
    static func key(for raw: String) -> String {
        let uniqueComponents = Set(components(of: raw))
        return uniqueComponents.sorted().joined(separator: "|")
    }

    /// A simplified, word-ordered form used as the text fed to the embedding
    /// model (expanded + lowercased, but not de-duplicated or sorted).
    static func simplified(_ raw: String) -> String {
        components(of: raw).joined(separator: " ")
    }

    /// Splits a place string into normalized, expanded components.
    private static func components(of raw: String) -> [String] {
        // Fold typographic apostrophes/quotes to nothing (so "Devil's" and
        // "Devil\u{2019}s" agree), then treat parentheses and commas alike.
        let separated = raw
            .lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")  // ’ right single quote
            .replacingOccurrences(of: "\u{2018}", with: "")  // ‘ left single quote
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "(", with: ",")
            .replacingOccurrences(of: ")", with: ",")

        var result: [String] = []
        for piece in separated.split(separator: ",") {
            var token = piece.trimmingCharacters(in: .whitespaces)
            token = token.replacingOccurrences(of: ".", with: "")
            // Collapse runs of internal whitespace to a single space.
            token = token.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !token.isEmpty, token != "city" else { continue }

            if let alias = placeAliases[token] { token = alias }
            if let state = stateExpansions[token] { token = state }
            result.append(token)
        }
        return result
    }
}

// MARK: - Results

/// A set of original spellings that normalize to the same canonical key.
struct PlaceDuplicateCluster: Identifiable {
    let canonicalKey: String
    let names: [String]
    var id: String { canonicalKey }
}

/// A pair of names the embedding model rates as near-identical, surfaced for
/// human review (they do *not* share a normalized key).
struct PlaceSimilarPair: Identifiable {
    let a: String
    let b: String
    let similarity: Double
    var id: String { "\(a)\u{1F}\(b)" }
}

// MARK: - Finder

/// Finds duplicate and near-duplicate place names.
struct PlaceDuplicateFinder {

    /// Cosine-similarity threshold for the embedding (review) tier. 0.0–1.0;
    /// higher = stricter. ~0.92 is a reasonable starting point for short names.
    var similarityThreshold: Double = 0.92

    /// Maximum number of review pairs to return (highest-similarity first).
    var maxCandidatePairs: Int = 100

    // MARK: Tier 1 — exact normalized-key clusters

    /// Groups names by canonical key and returns only the groups with more than
    /// one distinct original spelling. High confidence: these are duplicates.
    func exactKeyClusters(from names: [String]) -> [PlaceDuplicateCluster] {
        var groups: [String: [String]] = [:]
        for name in names {
            groups[PlaceNameNormalizer.key(for: name), default: []].append(name)
        }
        return groups
            .compactMap { key, spellings in
                let distinct = Array(Set(spellings)).sorted()
                guard distinct.count > 1 else { return nil }
                return PlaceDuplicateCluster(canonicalKey: key, names: distinct)
            }
            .sorted { $0.names.count > $1.names.count }
    }

    // MARK: Tier 2 — embedding near-duplicate candidates

    /// Returns pairs of names with cosine similarity above the threshold that do
    /// NOT already share a normalized key, ranked most-similar first. These are
    /// fuzzier candidates (nicknames, reworded forms) for human review.
    func embeddingCandidates(from names: [String]) -> [PlaceSimilarPair] {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            return []
        }

        // Extract one unit-normalized vector per name (so cosine == dot product).
        struct Item { let name: String; let key: String; let vector: [Double] }
        var items: [Item] = []
        items.reserveCapacity(names.count)
        for name in names {
            let text = PlaceNameNormalizer.simplified(name)
            guard let raw = embedding.vector(for: text), !raw.isEmpty else { continue }
            let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
            guard norm > 0 else { continue }
            items.append(Item(name: name,
                              key: PlaceNameNormalizer.key(for: name),
                              vector: raw.map { $0 / norm }))
        }

        var pairs: [PlaceSimilarPair] = []
        for i in items.indices {
            for j in (i + 1)..<items.count {
                guard items[i].key != items[j].key else { continue }
                let similarity = dot(items[i].vector, items[j].vector)
                if similarity >= similarityThreshold {
                    pairs.append(PlaceSimilarPair(
                        a: items[i].name, b: items[j].name, similarity: similarity
                    ))
                }
            }
        }

        return Array(pairs.sorted { $0.similarity > $1.similarity }.prefix(maxCandidatePairs))
    }

    private func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in a.indices { sum += a[i] * b[i] }
        return sum
    }
}
