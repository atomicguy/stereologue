//
//  CardListContext.swift
//  Stereologue
//
//  Passes the current card list from a grid view to the detail pager
//  so the user can swipe between cards.
//

import SwiftUI

@Observable
final class CardListContext {
    var cards: [StereoCard] = []
}
