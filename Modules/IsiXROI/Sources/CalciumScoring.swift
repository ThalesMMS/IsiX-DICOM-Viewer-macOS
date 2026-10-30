/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

// The rules of the calcium scoring window: the thresholds of each kind of
// scanner, the table of vessels and its totals, the colour of each vessel's
// ROIs, the age printed on the report and when a new ROI overlaps an older
// one. The window, the ROIs and the region growing stay in the app; the ROI
// computes its own score, mass and volume.

/// The scanner the score is computed for, and the thresholds that go with it.
public enum CalciumScoringScanner {
    /// The preference that remembers the scanner type.
    public static let defaultsKey = "CalciumScoreCTType"

    /// The upper threshold a new window starts with, in Hounsfield units.
    public static let defaultUpperThreshold: Int32 = 1500

    /// The lower threshold of a scanner type: 90 HU for electron beam CT (0),
    /// 130 HU for multi-slice CT (1); nil, the threshold kept, for any other.
    public static func lowerThreshold(ctType: Int32) -> Int32? {
        switch ctType {
        case 0: return 90
        case 1: return 130
        default: return nil
        }
    }
}

/// A score, a mass and a volume, summed in single precision as the window
/// summed them.
public struct CalciumScoreSums: Equatable, Sendable {
    public var score: Float
    public var mass: Float
    public var volume: Float

    public init(score: Float, mass: Float, volume: Float) {
        self.score = score
        self.mass = mass
        self.volume = volume
    }

    public static let zero = CalciumScoreSums(score: 0, mass: 0, volume: 0)

    /// Adds `other`, score, mass and volume in turn.
    public mutating func add(_ other: CalciumScoreSums) {
        score += other.score
        mass += other.mass
        volume += other.volume
    }
}

/// The table of vessels of the window: one row per vessel, then the Total row.
public enum CalciumScoringVessels {
    /// A row of the table, with nothing measured yet: its name and a score, a
    /// mass and a volume of 0, as the array controller of the window shows them.
    public static func row(name: String) -> NSMutableDictionary {
        let zero = NSNumber(value: Float(0))
        return NSMutableDictionary(dictionary: ["vesselName": name, "score": zero, "mass": zero, "volume": zero])
    }

    /// Whether `value` matches `pattern` as the predicate `x like pattern` does:
    /// the whole string, `*` and `?` as wildcards, case and diacritics counted.
    public static func matches(_ value: String, like pattern: String) -> Bool {
        NSPredicate(format: "SELF like %@", pattern).evaluate(with: value)
    }

    /// Whether `name` is one of `vesselNames`, compared as NSString compares.
    public static func contains(_ vesselNames: [String], name: String) -> Bool {
        vesselNames.contains(where: { ($0 as NSString).isEqual(to: name) })
    }

    /// Where a row for a new vessel name goes, if it needs one: before the last
    /// row (the Total row), when no row's name matches the new name taken as a
    /// pattern; nil when one does.
    public static func insertionIndex(forName name: String, rowNames: [String]) -> Int? {
        if rowNames.contains(where: { matches($0, like: name) }) { return nil }
        return rowNames.count - 1
    }
}

/// The totals of the table.
public enum CalciumScoreTotals {
    /// The rows of the table, in order: each row before the Total row gets the
    /// sums of its ROIs (`measures` gives them, read once per row and in row
    /// order); the Total row gets the sums of all the rows before it; the rows
    /// after it are not reached (nil). `total` is what the window shows as its
    /// totals: the running sums after the last row before the Total row, nil
    /// when there is none.
    public static func compute(rowNames: [String], totalName: String,
                               measures: (String) -> [CalciumScoreSums]) -> (rows: [CalciumScoreSums?], total: CalciumScoreSums?) {
        var rows = [CalciumScoreSums?](repeating: nil, count: rowNames.count)
        var running = CalciumScoreSums.zero
        var total: CalciumScoreSums?
        for (index, name) in rowNames.enumerated() {
            if (name as NSString).isEqual(to: totalName) {
                rows[index] = running
                break
            }
            var segment = CalciumScoreSums.zero
            for measure in measures(name) {
                running.add(measure)
                segment.add(measure)
            }
            rows[index] = segment
            total = running
        }
        return (rows, total)
    }
}

/// The colour a computed ROI is given after its vessel, as 16-bit RGB.
public enum CalciumScoringColor {
    /// Red for the left coronary artery, blue for the left anterior descending,
    /// yellow for the left circumflex, magenta for the right coronary artery and
    /// green for any other name. The vessel names are the localized ones.
    public static func color(roiName: String, leftCoronary: String, leftAnteriorDescending: String,
                             leftCircumflex: String, rightCoronary: String) -> (red: UInt16, green: UInt16, blue: UInt16) {
        let name = roiName as NSString
        if name.isEqual(to: leftCoronary) { return (65535, 0, 0) }
        if name.isEqual(to: leftAnteriorDescending) { return (0, 0, 65535) }
        if name.isEqual(to: leftCircumflex) { return (65535, 65535, 0) }
        if name.isEqual(to: rightCoronary) { return (65535, 0, 65535) }
        return (0, 65535, 0)
    }
}

/// What the printed report shows of the patient.
public enum CalciumScoringReport {
    /// The age at the study: "<years> Y", or "<months> M" under a year, or
    /// "<days> D" under a month. The counts are printed as 32-bit integers.
    public static func age(years: Int, months: Int, days: Int) -> String {
        if years > 0 { return String(format: "%d Y", Int32(truncatingIfNeeded: years)) }
        if months > 0 { return String(format: "%d M", Int32(truncatingIfNeeded: months)) }
        return String(format: "%d D", Int32(truncatingIfNeeded: days))
    }
}

/// Whether a ROI the region growing has just made overlaps an older one.
public enum CalciumScoringOverlap {
    /// Whether a pixel with a nonzero value in one ROI is a pixel with a nonzero
    /// value in the other. `values` holds one value per pixel and `locations` two
    /// coordinates per pixel (x, y), cut to integers as a C cast of a float on
    /// arm64 cuts them (toward zero, NaN as 0, saturated).
    public static func intersects(values: UnsafeBufferPointer<Float>, locations: UnsafeBufferPointer<Float>,
                                  newValues: UnsafeBufferPointer<Float>, newLocations: UnsafeBufferPointer<Float>) -> Bool {
        var newPixels = Set<Int64>()
        for j in 0 ..< newValues.count where newValues[j] != 0 {
            newPixels.insert(pixelKey(newLocations[j * 2], newLocations[j * 2 + 1]))
        }
        if newPixels.isEmpty { return false }
        for i in 0 ..< values.count where values[i] != 0 {
            if newPixels.contains(pixelKey(locations[i * 2], locations[i * 2 + 1])) { return true }
        }
        return false
    }

    /// The pixel (x, y) as one key.
    private static func pixelKey(_ x: Float, _ y: Float) -> Int64 {
        Int64(cInt(x)) << 32 | Int64(UInt32(bitPattern: cInt(y)))
    }

    /// `(int) value` on arm64: toward zero, NaN as 0, out of range saturated.
    static func cInt(_ value: Float) -> Int32 {
        if value.isNaN { return 0 }
        if value >= 2_147_483_648 { return Int32.max }
        if value < -2_147_483_648 { return Int32.min }
        return Int32(value)
    }
}
