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

struct MiddleTruncatedTitleTests {
    /// A button that holds `room` characters, the ellipsis being one.
    private func holding(_ room: Int) -> (String) -> Bool { { $0.count <= room } }

    @Test func aNameThatFitsIsShownWhole() {
        #expect(MiddleTruncatedTitle.title(of: "Linear Table", fits: holding(12)) == "Linear Table")
        #expect(MiddleTruncatedTitle.title(of: "", fits: holding(0)) == "")
        var asked: [String] = []
        _ = MiddleTruncatedTitle.title(of: "Default WL & WW") { asked.append($0); return true }
        #expect(asked == ["Default WL & WW"])
    }

    @Test func aNameThatDoesNotFitKeepsItsBeginningAndItsEnd() {
        let name = "Logarithmic Inverse Table"
        #expect(MiddleTruncatedTitle.title(of: name, fits: holding(17)) == "Logarith…se Table")
        #expect(MiddleTruncatedTitle.title(of: name, fits: holding(18)) == "Logarithm…se Table")
        #expect(MiddleTruncatedTitle.title(of: name, fits: holding(24)) == "Logarithmic…nverse Table")
        for room in 4...24 {
            let title = MiddleTruncatedTitle.title(of: name, fits: holding(room))
            #expect(title.count <= room, "\(title)")
            #expect(MiddleTruncatedTitle.isCut(title, of: name), "\(title)")
            // No room is left unused: one character more would not fit.
            #expect(title.count >= room - 1, "\(title) in \(room)")
        }
    }

    @Test func twoPresetsThatDifferAtEitherEndStayApart() {
        let fits = holding(15)
        let shown = ["Logarithmic Inverse Table", "Logarithmic Inverse Curve", "Exponential Inverse Table"].map {
            MiddleTruncatedTitle.title(of: $0, fits: fits)
        }
        #expect(Set(shown).count == 3, "\(shown)")
    }

    @Test func noSpaceStandsBesideTheEllipsis() {
        #expect(MiddleTruncatedTitle.title(of: "Bone CT of the left hand", fits: holding(10)) == "Bone…hand")
        #expect(MiddleTruncatedTitle.title(of: "ab cd ef gh", fits: holding(6)) == "ab…gh")
    }

    @Test func somethingOfBothEndsIsKeptWhenNothingFits() {
        #expect(MiddleTruncatedTitle.title(of: "Logarithmic Inverse Table", fits: { _ in false }) == "L…e")
        #expect(MiddleTruncatedTitle.title(of: "ab", fits: { _ in false }) == "ab")
        #expect(MiddleTruncatedTitle.title(of: "abc", fits: { _ in false }) == "a…c")
    }

    @Test func aCharacterOfSeveralScalarsIsNotSplit() {
        let name = "Coração 👩🏽‍⚕️ e pulmão 🇧🇷 do paciente"
        for room in 3...name.count {
            let title = MiddleTruncatedTitle.title(of: name, fits: holding(room))
            #expect(title == name || MiddleTruncatedTitle.isCut(title, of: name), "\(title)")
            #expect(title.unicodeScalars.allSatisfy { $0 != "\u{FFFD}" })
        }
        #expect(MiddleTruncatedTitle.title(of: "👩🏽‍⚕️abcdef🇧🇷", fits: holding(3)) == "👩🏽‍⚕️…🇧🇷")
    }

    @Test func aLongNameIsAskedAboutAFewTimes() {
        let name = String(repeating: "preset ", count: 400)
        var asked = 0
        let title = MiddleTruncatedTitle.title(of: name) { asked += 1; return $0.count <= 20 }
        #expect(title.count <= 20 && title.count >= 18)
        #expect(asked <= 16, "\(asked)")
    }

    @Test func aTitleIsKnownAsTheCutOfItsName() {
        #expect(MiddleTruncatedTitle.isCut("Logarith…se Table", of: "Logarithmic Inverse Table"))
        #expect(!MiddleTruncatedTitle.isCut("Logarithmic Inverse Table", of: "Logarithmic Inverse Table"))
        #expect(!MiddleTruncatedTitle.isCut("Linear…Table", of: "Logarithmic Inverse Table"))
        #expect(!MiddleTruncatedTitle.isCut("Logarithmic", of: "Logarithmic Inverse Table"))
    }
}
