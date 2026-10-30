//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

@Suite struct ViewerWindowsStateTests {

    static func entry(_ name: String) -> NSDictionary {
        NSDictionary(dictionary: ["name": name, "window position": "0 0 10 10", "screen": "{{0, 0}, {10, 10}}",
                                  "screenIndex": 0, "LastWindowsTilingRowsColumns": "11", "index": 3])
    }

    @Test func wholeLayoutOfOnePatient() {
        let state = [Self.entry("a"), Self.entry("b")]
        let own = ViewerWindowsState.entries(of: state, patients: ["Ãlvaro", "ÁLVARO"], patientUID: "álvaro")
        #expect(own.count == 2)
        #expect(own[0] === state[0] && own[1] === state[1])
    }

    @Test func partOfALayoutLosesTheLayoutKeys() throws {
        let state = [Self.entry("a"), Self.entry("b"), Self.entry("c")]
        let own = ViewerWindowsState.entries(of: state, patients: ["P1", "P2", "P1"], patientUID: "p1")
        #expect(own.map { $0["name"] as? String } == ["a", "c"])
        for entry in own {
            #expect(entry["index"] as? Int == 3)
            for key in ViewerWindowsState.layoutKeys { #expect(entry[key] == nil) }
        }
        #expect(state[0]["screen"] != nil)
    }

    @Test func missingPatientIsEmpty() {
        let own = ViewerWindowsState.entries(of: [Self.entry("a")], patients: [""], patientUID: nil)
        #expect(own.count == 1)
        #expect(ViewerWindowsState.entries(of: [Self.entry("a")], patients: ["X"], patientUID: nil).isEmpty)
        #expect(ViewerWindowsState.entries(of: [Self.entry("a")], patients: [], patientUID: "X").isEmpty)
    }

    @Test func seriesOfTheFrames() {
        #expect(ViewerWindowsState.seriesInstanceUID(of: []) == nil)
        #expect(ViewerWindowsState.seriesInstanceUID(of: ["1.2", "1.2"]) == "1.2")
        #expect(ViewerWindowsState.seriesInstanceUID(of: ["1.2", "1.3", "1.2"]) == "1.2\\**\\1.3\\**\\1.2")
    }

    @Test func windowPosition() {
        #expect(ViewerWindowsState.windowPosition(CGRect(x: 1.5, y: -2, width: 300, height: 200.25)) == "1.500000 -2.000000 300.000000 200.250000")
    }
}

@Suite struct ViewerWindowFrameTests {

    @Test func roundedAndAnimatedWhenLarge() {
        let change = ViewerWindowFrame.change(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                              to: CGRect(x: 10.4, y: 0.5, width: 200.6, height: 99.5), animate: true)
        #expect(change.frame == CGRect(x: 10, y: 1, width: 201, height: 100))
        #expect(!change.identical && change.animate)
    }

    @Test func smallMovesAreNotAnimated() {
        let change = ViewerWindowFrame.change(from: CGRect(x: 0, y: 0, width: 100, height: 100),
                                              to: CGRect(x: 4, y: 0, width: 100, height: 100), animate: true)
        #expect(!change.identical && !change.animate)
        let same = ViewerWindowFrame.change(from: CGRect(x: 0.6, y: 0, width: 100, height: 100),
                                            to: CGRect(x: 0.4, y: 0, width: 100, height: 100), animate: true)
        #expect(same.identical && !same.animate && same.frame.origin.x == 0)
    }

    @Test func zoomButton() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let first = ViewerWindowFrame.standardFrame(current: CGRect(x: 0, y: 0, width: 400, height: 300), screen: screen, standard: .zero)
        #expect(first.frame == screen && first.standard == CGRect(x: 0, y: 0, width: 400, height: 300))
        let back = ViewerWindowFrame.standardFrame(current: CGRect(x: 0, y: 0, width: 985, height: 790), screen: screen, standard: first.standard)
        #expect(back.frame == first.standard && back.standard == first.standard)
    }

    @Test func tilingMenu() {
        #expect(ViewerWindowFrame.tiling(tag: 23, screens: 2) == (2, 6))
        #expect(ViewerWindowFrame.tiling(tag: 11, screens: 1) == (1, 1))
    }
}
