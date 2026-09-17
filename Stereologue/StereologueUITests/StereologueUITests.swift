//
//  StereologueUITests.swift
//  StereologueUITests
//
//  Created by Adam Schuster on 7/7/25.
//

import XCTest

final class StereologueUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    /// Creates an album from a card's "Add to Album" menu, checks the card
    /// shows up in the album, removes it there, and deletes the album.
    @MainActor
    func testAlbumAddRemoveDelete() throws {
        let app = XCUIApplication()
        app.launch()
        let albumName = "UITest Album \(Int(Date().timeIntervalSince1970))"

        // Open the first card in the Library.
        let firstCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'A fellow feeling'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 30), app.debugDescription)
        firstCard.tap()

        // Add it to a brand-new album.
        let addToAlbum = app.buttons["Add to Album"]
        XCTAssertTrue(addToAlbum.waitForExistence(timeout: 10), app.debugDescription)
        addToAlbum.tap()
        let newAlbum = app.buttons["New Album…"]
        XCTAssertTrue(newAlbum.waitForExistence(timeout: 5), app.debugDescription)
        newAlbum.tap()
        let nameField = app.textFields["Album name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5), app.debugDescription)
        nameField.tap()
        nameField.typeText(albumName)
        app.buttons["Create"].tap()

        // The menu now shows the album checked.
        addToAlbum.tap()
        let membership = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", albumName)
        ).firstMatch
        XCTAssertTrue(membership.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(membership.isSelected, "album should be checked in the menu")
        app.tap() // dismiss the menu

        // Open the album from the sidebar.
        let sidebarToggle = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'sidebar'")
        ).firstMatch
        XCTAssertTrue(sidebarToggle.waitForExistence(timeout: 5), app.debugDescription)
        sidebarToggle.tap()
        let albumTab = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", albumName)
        ).firstMatch
        XCTAssertTrue(albumTab.waitForExistence(timeout: 5), app.debugDescription)
        albumTab.tap()

        // The card is there; remove it from the album via the context menu.
        let albumCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'A fellow feeling'")
        ).firstMatch
        XCTAssertTrue(albumCard.waitForExistence(timeout: 10), app.debugDescription)
        albumCard.press(forDuration: 1.0)
        let remove = app.buttons["Remove from Album"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.tap()
        XCTAssertTrue(app.staticTexts["Empty Album"].waitForExistence(timeout: 10), app.debugDescription)

        // Delete the album.
        app.buttons["Album Options"].tap()
        let deleteItem = app.buttons["Delete Album"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 5), app.debugDescription)
        deleteItem.tap()
        let confirm = app.buttons["Delete Album"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()

        // Selection falls back to the Library tab and the album's tab is gone.
        let libraryTab = app.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), app.debugDescription)
        let selected = NSPredicate(format: "isSelected == true")
        let libraryIsSelected = expectation(for: selected, evaluatedWith: libraryTab)
        wait(for: [libraryIsSelected], timeout: 10)
        XCTAssertFalse(albumTab.exists, app.debugDescription)
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
