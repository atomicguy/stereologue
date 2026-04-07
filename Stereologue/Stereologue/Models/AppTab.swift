//
//  AppTab.swift
//  Stereologue
//
//  Tab identity for the root TabView selection binding.
//

import Foundation

enum AppTab: Hashable {
    // Top-level
    case library
    case favorites

    // Browse section
    case dates
    case subjects
    case creators
    case places
    case collections

    // Albums (dynamic — one tab per user album)
    case album(UUID)

    // Search
    case search
}
