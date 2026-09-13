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
    /// All cards available for browsing in the spatial viewer, as lightweight
    /// rows. The viewer resolves the full model only for the card on screen.
    private(set) var rows: [CardRow] = []
    private var indexByUUID: [String: Int] = [:]

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

    var currentRow: CardRow? {
        currentIndex.map { rows[$0] }
    }

    var currentIndex: Int? {
        currentCardUUID.flatMap { indexByUUID[$0] }
    }

    func index(of uuid: String) -> Int? {
        indexByUUID[uuid]
    }

    var hasPrevious: Bool {
        guard let idx = currentIndex else { return false }
        return idx > 0
    }

    var hasNext: Bool {
        guard let idx = currentIndex else { return false }
        return idx < rows.count - 1
    }

    // MARK: - Navigation

    func goToNext() {
        guard let idx = currentIndex, idx < rows.count - 1 else { return }
        navigationDirection = .forward
        currentCardUUID = rows[idx + 1].uuid
    }

    func goToPrevious() {
        guard let idx = currentIndex, idx > 0 else { return }
        navigationDirection = .backward
        currentCardUUID = rows[idx - 1].uuid
    }

    // MARK: - Setup

    func present(rows: [CardRow], initialCardUUID: String) {
        self.rows = rows
        var index: [String: Int] = [:]
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() where index[row.uuid] == nil {
            index[row.uuid] = i
        }
        indexByUUID = index
        currentCardUUID = initialCardUUID
        navigationDirection = .forward
        isPresented = true
    }

    func dismiss() {
        isPresented = false
        rows = []
        indexByUUID = [:]
        currentCardUUID = nil
    }
}

#endif
