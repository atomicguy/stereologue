//
//  SpatialPhotoViewModel.swift
//  Stereologue
//
//  Observable model that shares spatial photo viewing state between
//  the main window and the spatial photo window.
//

#if os(visionOS)

import SwiftUI

@Observable @MainActor
final class SpatialPhotoViewModel {
    /// All cards available for browsing in the spatial viewer.
    var cards: [StereoCard] = []

    /// UUID of the currently displayed card.
    var currentCardUUID: String?

    /// Direction of the last navigation, used for push transition.
    var navigationDirection: NavigationDirection = .forward

    /// Whether the spatial photo window is currently presented.
    var isPresented = false

    enum NavigationDirection {
        case forward, backward
    }

    // MARK: - Computed

    var currentCard: StereoCard? {
        cards.first { $0.uuid == currentCardUUID }
    }

    var currentIndex: Int? {
        cards.firstIndex { $0.uuid == currentCardUUID }
    }

    var hasPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }

    var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < cards.count - 1
    }

    // MARK: - Navigation

    func goToNext() {
        guard let idx = currentIndex, idx < cards.count - 1 else { return }
        navigationDirection = .forward
        currentCardUUID = cards[idx + 1].uuid
    }

    func goToPrevious() {
        guard let idx = currentIndex, idx > 0 else { return }
        navigationDirection = .backward
        currentCardUUID = cards[idx - 1].uuid
    }

    // MARK: - Setup

    func present(cards: [StereoCard], initialCardUUID: String) {
        self.cards = cards
        self.currentCardUUID = initialCardUUID
        self.navigationDirection = .forward
        self.isPresented = true
    }

    func dismiss() {
        isPresented = false
        cards = []
        currentCardUUID = nil
    }
}

#endif
