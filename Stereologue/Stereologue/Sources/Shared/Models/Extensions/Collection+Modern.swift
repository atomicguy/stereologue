// Collection+Modern.swift
// Updated with Swift 6.2 patterns and Liquid Glass design support

import Foundation
import SwiftData
import SwiftUI

extension CollectionSchemaV1.Collection {
    
    // MARK: - Smart Organization
    func reorderCardsIntelligently() async {
        let sortedCards = cards.sorted { card1, card2 in
            compareCardsForOrdering(card1, card2)
        }
        
        cardOrder = sortedCards.map { $0.uuid }
        updatedAt = Date()
    }
    
    var suggestedCards: [CardSchemaV1.StereoCard] {
        // AI suggestions for cards that might belong in this collection
        return []
    }
    
    // MARK: - Liquid Glass Design Support
    var adaptiveTheme: CollectionTheme {
        let dominantColors = extractDominantColors()
        let mood = analyzeMood()
        
        return CollectionTheme(
            primaryColor: dominantColors.primary,
            accentColor: dominantColors.accent,
            glassMorphism: GlassMorphismStyle(
                blur: calculateOptimalBlur(),
                opacity: calculateOptimalOpacity(),
                saturation: mood.saturation
            ),
            typography: selectOptimalTypography(for: mood)
        )
    }
    
    var visualDensity: VisualDensity {
        switch cards.count {
        case 0...10: return .spacious
        case 11...50: return .comfortable  
        case 51...200: return .compact
        default: return .dense
        }
    }
    
    // MARK: - Performance Optimizations (Swift 6.2)
    func loadCardsInBatches(batchSize: Int = 20) -> AsyncSequence<[CardSchemaV1.StereoCard], Never> {
        AsyncStream { continuation in
            Task {
                let sorted = orderedCards
                for chunk in sorted.chunked(into: batchSize) {
                    continuation.yield(chunk)
                    try? await Task.sleep(nanoseconds: 1_000_000)
                }
                continuation.finish()
            }
        }
    }
    
    func preloadThumbnails() async {
        await withTaskGroup(of: Void.self) { group in
            for card in orderedCards.prefix(50) {
                group.addTask {
                    await card.ensureThumbnailLoaded()
                }
            }
        }
    }
    
    // MARK: - Analytics and Insights
    var collectionInsights: CollectionInsights {
        CollectionInsights(
            totalCards: cards.count,
            dateRange: calculateDateRange(),
            topSubjects: extractTopSubjects(),
            topAuthors: extractTopAuthors(),
            geographicSpread: analyzeGeography(),
            completenessScore: calculateCompleteness(),
            lastActivity: updatedAt
        )
    }
    
    func generateCollectionSummary() async -> String {
        let insights = collectionInsights
        
        return """
        This collection contains \(insights.totalCards) stereoscopic cards \
        spanning \(insights.dateRange?.description ?? "various periods"). \
        The most common subjects are \(insights.topSubjects.prefix(3).joined(separator: ", ")). \
        Collection completeness: \(Int(insights.completenessScore * 100))%
        """
    }
}

// MARK: - Private Helpers
private extension CollectionSchemaV1.Collection {
    
    func compareCardsForOrdering(_ card1: CardSchemaV1.StereoCard, _ card2: CardSchemaV1.StereoCard) -> Bool {
        // 1. Date-based sorting (if available)
        if let date1 = card1.dates.first?.text,
           let date2 = card2.dates.first?.text {
            return date1 < date2
        }
        
        // 2. Subject coherence
        let sharedSubjects1 = calculateSubjectCoherence(for: card1)
        let sharedSubjects2 = calculateSubjectCoherence(for: card2)
        
        if sharedSubjects1 != sharedSubjects2 {
            return sharedSubjects1 > sharedSubjects2
        }
        
        // 3. Title sorting as fallback
        let title1 = card1.titlePick?.text ?? ""
        let title2 = card2.titlePick?.text ?? ""
        return title1 < title2
    }
    
    func calculateSubjectCoherence(for card: CardSchemaV1.StereoCard) -> Int {
        let cardSubjects = Set(card.subjects.map { $0.name })
        let collectionSubjects = Set(cards.flatMap { $0.subjects.map { $0.name } })
        
        return cardSubjects.intersection(collectionSubjects).count
    }
    
    func extractDominantColors() -> (primary: Color, accent: Color) {
        return (primary: .blue, accent: .orange) // Placeholder
    }
    
    func analyzeMood() -> (saturation: Double) {
        return (saturation: 1.0) // Placeholder
    }
    
    func calculateOptimalBlur() -> Double { 10.0 }
    func calculateOptimalOpacity() -> Double { 0.8 }
    
    func selectOptimalTypography(for mood: (saturation: Double)) -> TypographyStyle {
        return .modern
    }
    
    func calculateDateRange() -> DateInterval? {
        return nil // Placeholder
    }
    
    func extractTopSubjects() -> [String] {
        let allSubjects = cards.flatMap { $0.subjects.map { $0.name } }
        let counts = Dictionary(grouping: allSubjects, by: { $0 })
            .mapValues { $0.count }
        
        return counts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
    }
    
    func extractTopAuthors() -> [String] {
        let allAuthors = cards.flatMap { $0.authors.map { $0.name } }
        let counts = Dictionary(grouping: allAuthors, by: { $0 })
            .mapValues { $0.count }
        
        return counts.sorted { $0.value > $1.value }
            .prefix(5)
            .map { $0.key }
    }
    
    func analyzeGeography() -> [String] {
        return [] // Placeholder
    }
    
    func calculateCompleteness() -> Double {
        let totalFields = cards.count * 4
        let filledFields = cards.reduce(0) { total, card in
            total + 
            (card.titlePick != nil ? 1 : 0) +
            (card.authors.isEmpty ? 0 : 1) +
            (card.subjects.isEmpty ? 0 : 1) +
            (card.dates.isEmpty ? 0 : 1)
        }
        
        return totalFields > 0 ? Double(filledFields) / Double(totalFields) : 0
    }
}

// MARK: - Extensions
extension CardSchemaV1.StereoCard {
    func ensureThumbnailLoaded() async {
        // Background thumbnail loading logic
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}