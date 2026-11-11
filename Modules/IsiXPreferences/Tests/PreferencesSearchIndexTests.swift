//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import XCTest
@testable import IsiXPreferences

final class PreferencesSearchIndexTests: XCTestCase {
    private func index() -> PreferencesSearchIndex<String> {
        var index = PreferencesSearchIndex<String>()
        index.add(pane: "viewers", title: "Viewers", labels: ["Show Magnifying Lens with 'shift' key", "Reversed order"])
        index.add(pane: "listener", title: "Listener", labels: ["Número máximo de associações", "Reversed scan"])
        index.add(pane: "plugin", title: "Plugin Tools", labels: [])
        return index
    }

    func testALabelLeadsToItsPane() {
        XCTAssertEqual(index().panes(matching: "lens"), ["viewers"])
    }

    func testEveryPaneThatHoldsTheTermIsListedInOrder() {
        XCTAssertEqual(index().panes(matching: "reversed"), ["viewers", "listener"])
    }

    func testCaseAndAccentsDoNotCount() {
        XCTAssertEqual(index().panes(matching: "NUMERO ASSOCIACOES"), ["listener"])
    }

    func testAllTheWordsHaveToBeInOneLabel() {
        XCTAssertEqual(index().panes(matching: "lens order"), [])
    }

    func testAPluginPaneIsFoundByItsTitle() {
        XCTAssertEqual(index().panes(matching: "plugin"), ["plugin"])
    }

    func testAnEmptyTermMatchesNothing() {
        XCTAssertEqual(index().panes(matching: "  "), [])
        XCTAssertFalse(PreferencesSearchIndex<String>.label("Anything", matches: ""))
    }

    func testALabelCanBeCheckedAlone() {
        XCTAssertTrue(PreferencesSearchIndex<String>.label("Número máximo", matches: "numero"))
        XCTAssertFalse(PreferencesSearchIndex<String>.label("Número máximo", matches: "minimo"))
    }
}
