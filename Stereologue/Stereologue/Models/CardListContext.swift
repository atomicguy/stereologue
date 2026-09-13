//
//  CardListContext.swift
//  Stereologue
//
//  Passes the current grid's card list to the detail pager so the user can
//  swipe between cards.
//

import SwiftUI

/// The rows of whichever card grid is currently on screen, plus an index so
/// the pager can find a card's position in O(1) instead of scanning.
@Observable
final class CardListContext {
    private(set) var rows: [CardRow] = []
    private(set) var indexByUUID: [String: Int] = [:]

    func update(_ rows: [CardRow]) {
        self.rows = rows
        var index: [String: Int] = [:]
        index.reserveCapacity(rows.count)
        for (i, row) in rows.enumerated() where index[row.uuid] == nil {
            index[row.uuid] = i
        }
        indexByUUID = index
    }

    func index(of uuid: String) -> Int? {
        indexByUUID[uuid]
    }
}
