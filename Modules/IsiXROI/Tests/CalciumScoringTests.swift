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
@testable import IsiXROI

// Values worked out by hand. The comparison with the Objective-C the module
// replaced runs outside the package, in tests/.
@Suite struct CalciumScoringTests {
    @Test func thresholdsOfEachScanner() {
        #expect(CalciumScoringScanner.lowerThreshold(ctType: 0) == 90)
        #expect(CalciumScoringScanner.lowerThreshold(ctType: 1) == 130)
        #expect(CalciumScoringScanner.lowerThreshold(ctType: 2) == nil)
    }

    @Test func totalsStopAtTheTotalRow() {
        let measures: [String: [CalciumScoreSums]] = [
            "A": [CalciumScoreSums(score: 1, mass: 2, volume: 3), CalciumScoreSums(score: 10, mass: 20, volume: 30)],
            "B": [],
            "C": [CalciumScoreSums(score: 100, mass: 0, volume: 0)],
        ]
        let result = CalciumScoreTotals.compute(rowNames: ["A", "B", "Total", "C"], totalName: "Total") { measures[$0] ?? [] }
        #expect(result.rows[0] == CalciumScoreSums(score: 11, mass: 22, volume: 33))
        #expect(result.rows[1] == .zero)
        #expect(result.rows[2] == CalciumScoreSums(score: 11, mass: 22, volume: 33))
        #expect(result.rows[3] == nil)
        #expect(result.total == CalciumScoreSums(score: 11, mass: 22, volume: 33))
        #expect(CalciumScoreTotals.compute(rowNames: ["Total"], totalName: "Total") { _ in [] }.total == nil)
    }

    @Test func vesselRowsAndColours() {
        #expect(CalciumScoringVessels.matches("Left Coronary Artery", like: "Left*"))
        #expect(!CalciumScoringVessels.matches("Left Coronary Artery", like: "left*"))
        #expect(CalciumScoringVessels.insertionIndex(forName: "Plaque", rowNames: ["A", "B", "Total"]) == 2)
        #expect(CalciumScoringVessels.insertionIndex(forName: "?", rowNames: ["A", "B", "Total"]) == nil)
        let row = CalciumScoringVessels.row(name: "A")
        #expect(row["vesselName"] as? String == "A")
        #expect((row["score"] as? NSNumber)?.floatValue == 0)
        let colour = CalciumScoringColor.color(roiName: "LAD", leftCoronary: "LCA", leftAnteriorDescending: "LAD",
                                               leftCircumflex: "LCX", rightCoronary: "RCA")
        #expect(colour == (0, 0, 65535))
    }

    @Test func ageAndOverlap() {
        #expect(CalciumScoringReport.age(years: 40, months: 3, days: 2) == "40 Y")
        #expect(CalciumScoringReport.age(years: 0, months: 3, days: 2) == "3 M")
        #expect(CalciumScoringReport.age(years: 0, months: 0, days: 2) == "2 D")
        let values: [Float] = [0, 1], locations: [Float] = [5, 5, 6.7, 7]
        let newValues: [Float] = [2], newLocations: [Float] = [6, 7.9]
        let overlap = values.withUnsafeBufferPointer { v in locations.withUnsafeBufferPointer { l in
            newValues.withUnsafeBufferPointer { nv in newLocations.withUnsafeBufferPointer { nl in
                CalciumScoringOverlap.intersects(values: v, locations: l, newValues: nv, newLocations: nl) } } } }
        #expect(overlap)
        #expect(CalciumScoringOverlap.cInt(.nan) == 0)
        #expect(CalciumScoringOverlap.cInt(-3e9) == Int32.min)
    }
}
