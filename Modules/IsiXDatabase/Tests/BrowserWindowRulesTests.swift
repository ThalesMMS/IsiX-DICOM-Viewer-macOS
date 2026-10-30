//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Testing
@testable import IsiXDatabase

private struct Facts: BrowserMenuFacts {
    var rows: [(type: Any?, locked: Any?)] = []
    var local = true
    var readOnly = false
    var thumbnailItem = false
    var listItem = false
    var listResponder = false
    var annotations = 0
    var tag = 0

    func selectedCount() -> Int { rows.count }
    func selectedType(at position: Int) -> Any? { rows[position].type }
    func selectedLocked(at position: Int) -> Any? { rows[position].locked }
    func databaseIsLocal() -> Bool { local }
    func databaseIsReadOnly() -> Bool { readOnly }
    func firstSelectedHasItem() -> Bool { !rows.isEmpty }
    func firstSelectedStudyHasReport() -> Bool { false }
    func isImageTileMenu() -> Bool { false }
    func mainWindowIsViewer() -> Bool { false }
    func commentsAutoFill() -> Bool { true }
    func roiImageCount() -> Int { 0 }
    func roisAndKeyImageCount() -> Int { 0 }
    func keyImageCount() -> Int { 0 }
    func isThumbnailMenuItem() -> Bool { thumbnailItem }
    func selectionHasLinkedFiles(fromThumbnails: Bool) -> Bool { fromThumbnails }
    func firstResponderIsThumbnails() -> Bool { false }
    func isListMenuItem() -> Bool { listItem }
    func firstResponderIsList() -> Bool { listResponder }
    func firstResponderIsHistory() -> Bool { false }
    func selectedThumbnailCount() -> Int { 0 }
    func itemTag() -> Int { tag }
    func annotationsMode() -> Int { annotations }
}

struct BrowserWindowRulesTests {
    @Test func menuCommandsFollowTheSelection() {
        let study: (type: Any?, locked: Any?) = ("Study", NSNumber(value: false))
        let series: (type: Any?, locked: Any?) = ("Series", nil)
        #expect(!BrowserMenuValidation.validate(action: "viewerDICOM:", containsDistantStudy: false, facts: Facts()).enabled)
        #expect(BrowserMenuValidation.validate(action: "querySelectedStudy:", containsDistantStudy: true, facts: Facts(rows: [study])).enabled)
        #expect(!BrowserMenuValidation.validate(action: "retrieveSelectedPODStudies:", containsDistantStudy: false, facts: Facts(rows: [study])).enabled)
        #expect(!BrowserMenuValidation.validate(action: "delItem:", containsDistantStudy: false, facts: Facts(rows: [study], readOnly: true)).enabled)
        #expect(!BrowserMenuValidation.validate(action: "addAlbum:", containsDistantStudy: false, facts: Facts(local: false)).enabled)

        let merge = BrowserMenuValidation.validate(action: "mergeStudies:", containsDistantStudy: false, facts: Facts(rows: [series, series]))
        #expect(merge == .init(enabled: true, title: .mergeSelectedSeries))
        #expect(BrowserMenuValidation.validate(action: "mergeStudies:", containsDistantStudy: false, facts: Facts(rows: [study])) == .init(enabled: false, title: .mergeSelectedStudies))

        #expect(BrowserMenuValidation.validate(action: "delItem:", containsDistantStudy: false, facts: Facts(rows: [study])).title == .deleteSelectedSeriesThumbnails)
        #expect(BrowserMenuValidation.validate(action: "delItem:", containsDistantStudy: false, facts: Facts(rows: [study], listResponder: true)).title == .deleteSelectedLines)

        #expect(BrowserMenuValidation.validate(action: "lockStudies:", containsDistantStudy: false, facts: Facts(rows: [series, study])).enabled)
        #expect(!BrowserMenuValidation.validate(action: "unlockStudies:", containsDistantStudy: false, facts: Facts(rows: [series, study])).enabled)
        #expect(BrowserMenuValidation.validate(action: "annotMenu:", containsDistantStudy: false, facts: Facts(annotations: 2, tag: 2)).checked == true)
        #expect(BrowserMenuValidation.validate(action: "copyToDBFolder:", containsDistantStudy: false, facts: Facts(rows: [study], thumbnailItem: true)).enabled)
    }

    @Test func keysAndModifiers() {
        #expect(BrowserKeyCommand.of(character: 0x7F) == .delete)
        #expect(BrowserKeyCommand.of(character: 0x0D) == .open)
        #expect(BrowserKeyCommand.of(character: 0x20) == .toggleAnimation)
        #expect(BrowserKeyCommand.of(character: 0x41) == .typeSelect)
        #expect(BrowserModifierKeys.eventFlags(carbonModifiers: 0x0100 | 0x0800) == (1 << 20 | 1 << 19))
        #expect(BrowserModifierKeys.eventFlags(carbonModifiers: 0x0400) == 0)
    }

    @Test func animationOfTheSelectedRow() {
        #expect(PreviewAnimation.frames(type: "Series", seriesImageCount: { 1 }, firstImageFrames: { NSNumber(value: 12) }, studyImages: { nil })
                == .slider(animate: true, images: 12))
        #expect(PreviewAnimation.frames(type: "Series", seriesImageCount: { 3 }, firstImageFrames: { nil }, studyImages: { nil })
                == .slider(animate: true, images: 3))
        #expect(PreviewAnimation.frames(type: "Study", seriesImageCount: { 0 }, firstImageFrames: { nil }, studyImages: { nil }) == .refresh)
        #expect(PreviewAnimation.frames(type: "Study", seriesImageCount: { 0 }, firstImageFrames: { nil }, studyImages: { (1, { "1" as NSString }) })
                == .slider(animate: false, images: 1))
        #expect(PreviewAnimation.sliderChange(animate: true, sliderEnabled: true, images: 4) == .keep)
        #expect(PreviewAnimation.sliderChange(animate: false, sliderEnabled: true, images: 4) == .disable)
    }

    @Test func savedSortSearchMenuAndDefaultDatabase() {
        #expect(ListSort.restored(saved: nil, isVisible: { _ in true }) == .byName)
        #expect(ListSort.restored(saved: ["key": "date", "order": NSNumber(value: false)], isVisible: { _ in true }) == .saved(key: "date", ascending: false))
        #expect(ListSort.restored(saved: ["key": "date"], isVisible: { _ in false }) == .byName)
        #expect(ListSort.saved(ascending: true, key: nil) == ["order": NSNumber(value: true)])
        #expect(SearchMenuTemplate.seriesDescriptionIndex(itemCount: 6, indexOfTag4: 3) == 4)
        #expect(SearchMenuTemplate.seriesDescriptionIndex(itemCount: 2, indexOfTag4: -1) == 0)
        #expect(DefaultDatabase.needsReset(shown: nil, defaultPath: "/a"))
        #expect(!DefaultDatabase.needsReset(shown: "/a", defaultPath: "/a"))
        #expect(PreviewReuse.index(count: 3, path: { ["/a", "/b", "/b"][$0] as NSString }, frame: { [0, 0, 2][$0] as NSNumber },
                                   pathToFind: "/b", frameNumber: 2) == 2)
    }
}
