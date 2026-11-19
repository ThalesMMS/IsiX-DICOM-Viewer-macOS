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
@testable import IsiXImaging

@Suite struct DocumentPagePolarityTests {

    /// Two ARGB pixels of a page: white paper, then black ink.
    private let page = Data([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00])

    /// A planar snapshot, as the view assembles it.
    private func snapshot(_ entries: [String: Any]) -> NSDictionary { entries as NSDictionary }

    /// `bytes` looked up in `table`, as vImageTableLookUp_ARGB8888 looks them up.
    private func lookUp(_ bytes: Data, _ table: [UInt8]) -> [UInt8] {
        bytes.enumerated().map { offset, value in table[(offset % 4) * 256 + Int(value)] }
    }

    @Test func invertsOnlyADocumentPageInDarkMode() {
        #expect(DocumentPagePolarity.inverts(isDocumentPage: true, darkAppearance: true, invertsInDarkMode: true))
        #expect(!DocumentPagePolarity.inverts(isDocumentPage: true, darkAppearance: false, invertsInDarkMode: true))
        #expect(!DocumentPagePolarity.inverts(isDocumentPage: true, darkAppearance: true, invertsInDarkMode: false))
        #expect(!DocumentPagePolarity.inverts(isDocumentPage: false, darkAppearance: true, invertsInDarkMode: true))
        #expect(!DocumentPagePolarity.inverts(isDocumentPage: false, darkAppearance: false, invertsInDarkMode: false))
    }

    @Test func readsTheAppearanceAndThePreferenceOnlyForADocumentPage() {
        var reads = 0
        func read(_ value: Bool) -> Bool {
            reads += 1
            return value
        }
        // Outside #expect, which shows the value of each argument it is given.
        let image = DocumentPagePolarity.inverts(isDocumentPage: false, darkAppearance: read(true), invertsInDarkMode: read(true))
        #expect(!image && reads == 0)
        let page = DocumentPagePolarity.inverts(isDocumentPage: true, darkAppearance: read(true), invertsInDarkMode: read(true))
        #expect(page && reads == 2)
    }

    @Test func turnsTheIdentityAround() throws {
        let table = try #require(DocumentPagePolarity.invertedColourTable(over: nil))
        let ramp = (0..<256).map { 255 - UInt8($0) }
        #expect(table == [UInt8](repeating: 0xFF, count: 256) + ramp + ramp + ramp)
    }

    @Test func turnsAroundTheTableTheViewLays() throws {
        // The B/W Inverse colour table over a colour image, with an alpha a
        // fusion would lay: turned around again, the colours are the page's
        // and the alpha is kept.
        let ramp = (0..<256).map { UInt8($0) }
        var inverse = [UInt8](repeating: 0xFF, count: 256) + Array(repeating: ramp.map { 255 - $0 }, count: 3).joined()
        inverse[3] = 0x80
        let table = try #require(DocumentPagePolarity.invertedColourTable(over: inverse))
        #expect(Array(table[0..<256]) == Array(inverse[0..<256]))
        #expect(Array(table[256...]) == ramp + ramp + ramp)
        #expect(DocumentPagePolarity.invertedColourTable(over: [UInt8](repeating: 0, count: 1023)) == nil)
    }

    @Test func laysTheInvertedTableOverAColourPageOnlyWhenAsked() throws {
        let colour = snapshot(["width": 2, "height": 1, "isColor": true, "pixels": page, "hostBytes": page])
        #expect(DocumentPagePolarity.shown(colour, inverted: false) === colour)

        let shown = DocumentPagePolarity.shown(colour, inverted: true)
        let table = [UInt8](try #require(shown["colourTable"] as? Data))
        #expect(table == DocumentPagePolarity.invertedColourTable(over: nil))
        // The page on screen: light ink on a dark page, opaque.
        #expect(lookUp(page, table) == [0xFF, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF])
        // Only the table is new: the bytes, and the snapshot given, which a
        // capture reads, stay the page's.
        #expect(shown["hostBytes"] as? Data == page && shown["pixels"] as? Data == page)
        #expect(colour["colourTable"] == nil && colour.count == 5)
    }

    @Test func invertsTheTableAColourPageAlreadyCarries() throws {
        let identity = [UInt8](repeating: 0xFF, count: 256) + Array(repeating: (0..<256).map { UInt8($0) }, count: 3).joined()
        let tabled = snapshot(["isColor": true, "hostBytes": page, "colourTable": Data(identity)])
        let table = [UInt8](try #require(DocumentPagePolarity.shown(tabled, inverted: true)["colourTable"] as? Data))
        #expect(table == DocumentPagePolarity.invertedColourTable(over: identity))
        #expect(tabled["colourTable"] as? Data == Data(identity))
    }

    @Test func leavesWhatATableCannotBeLaidOver() {
        let floats = snapshot(["isColor": false, "pixels": Data(count: 8)])
        #expect(DocumentPagePolarity.shown(floats, inverted: true) === floats)
        let withoutBytes = snapshot(["isColor": true, "pixels": page])
        #expect(DocumentPagePolarity.shown(withoutBytes, inverted: true) === withoutBytes)
        let packed = snapshot(["isColor": true, "hostBytes": page, "bytesCarryAlpha": true])
        #expect(DocumentPagePolarity.shown(packed, inverted: true) === packed)
        let malformed = snapshot(["isColor": true, "hostBytes": page, "colourTable": Data(count: 12)])
        #expect(DocumentPagePolarity.shown(malformed, inverted: true) === malformed)
    }
}
