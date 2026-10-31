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
@testable import IsiXPreferences

/// The marks of a change of the preferences, over the factory settings as the
/// application registers them.
@Suite struct PreferenceChangeTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]

    private func change(_ before: [String: Any?], _ after: [String: Any?]) -> PreferenceChange? {
        var previous = factory, current = factory
        for (key, value) in before { previous[key] = value }
        for (key, value) in after { current[key] = value }
        return PreferenceChange(from: previous, to: current)
    }

    @Test func equalPreferencesAskForNothing() {
        #expect(PreferenceChange(from: factory, to: factory) == nil)
        #expect(PreferenceChange(from: [:], to: [:]) == nil)
        // A number and a Boolean of the same value are one property list.
        #expect(PreferenceChange(from: ["A": NSNumber(value: 1)], to: ["A": true]) == nil)
    }

    @Test func numbersAreComparedByValueNotByType() throws {
        // Registered as text, written as a number by a pane: not a change. A
        // typed cast made every check see these keys change and refresh every
        // viewer.
        for (key, number) in [("ROILengthUnit", NSNumber(value: 0)), ("ROILengthDecimals", NSNumber(value: 3)),
                              ("LabelFONTSIZE", NSNumber(value: 12)),
                              ("NOINTERPOLATION", NSNumber(value: 0)), ("SOFTWAREINTERPOLATION", NSNumber(value: 1)),
                              ("SeriesListVisible", NSNumber(value: 1)), ("httpWebServerPort", NSNumber(value: 3333)),
                              ("ROILabelBackground", NSNumber(value: true)), ("UseFloatingThumbnailsList", NSNumber(value: true))] {
            let marks = try #require(change([:], [key: number]), "\(key)")
            #expect(marks == PreferenceChange(), "\(key) written as a number of its registered value")
        }
    }

    @Test func copySettingsIsNotAChange() throws {
        // The tiling, Sync, fusion and the hanging protocols turn it off and on
        // around their own work; no viewer draws it.
        let marks = try #require(change(["COPYSETTINGS": "1"], ["COPYSETTINGS": false]))
        #expect(marks == PreferenceChange())
    }

    @Test func eachKeyMarksWhatItAsksFor() throws {
        func marks(_ key: String, _ before: Any?, _ after: Any?) throws -> PreferenceChange {
            try #require(change([key: before], [key: after]), "\(key)")
        }
        var expected = PreferenceChange()
        expected.seriesListMode = true
        #expect(try marks("UseFloatingThumbnailsList", "1", false) == expected)
        expected = PreferenceChange()
        expected.seriesListVisible = true
        #expect(try marks("SeriesListVisible", "1", 0) == expected)
        expected = PreferenceChange()
        expected.viewerReload = true
        #expect(try marks("DisplayDICOMOverlays", "1", "0") == expected)
        expected = PreferenceChange()
        expected.viewerRedraw = true
        #expect(try marks("ShowPreviousExamLabel", true, false) == expected)

        expected = PreferenceChange()
        expected.viewerRefresh = true
        for key in ["ROIPRIMARYMEASUREMENTONLY", "ROILabelShowArea", "ROILabelShowWH", "ROILabelShowMean", "ROILabelShowSDev",
                    "ROILabelShowSum", "ROILabelShowMedian", "ROILabelShowMin", "ROILabelShowMax", "ROITEXTIFSELECTED"] {
            let before = Bool.reading(factory[key])
            #expect(try marks(key, before, !before) == expected, "\(key)")
        }
        #expect(try marks("ROITEXTNAMEONLY", "0", true) == expected)
        #expect(try marks("ROILabelBackground", "1", 0) == expected)
        #expect(try marks("ROILabelBackgroundOpacity", NSNumber(value: Float(0.8)), "0.5") == expected)
        #expect(try marks("NOINTERPOLATION", "0", 1) == expected)
        #expect(try marks("SOFTWAREINTERPOLATION", "1", 0) == expected)

        expected.lengthPresentation = true
        #expect(try marks("ROILengthUnit", "0", 2) == expected)
        #expect(try marks("ROILengthDecimals", "3", "1") == expected)

        expected = PreferenceChange()
        expected.labelFontSize = true
        #expect(try marks("LabelFONTSIZE", "12", 14.5) == expected)

        expected = PreferenceChange()
        expected.petBlendingCLUT = true
        #expect(try marks("PET Blending CLUT", "PET", "Hot Iron") == expected)
        #expect(try marks("PET Blending CLUT", "PET", nil) == expected)

        expected = PreferenceChange()
        expected.databaseRefresh = true
        #expect(try marks("DBDateFormat2", "dd/MM/yyyy", "yyyy-MM-dd") == expected)
        #expect(try marks("DBDateOfBirthFormat2", "dd/MM/yyyy", "yyyy-MM-dd") == expected)
        for (key, before, after) in [("HIDEPATIENTNAME", "0", 1), ("SERIESORDER", "0", 2), ("KeepStudiesOfSamePatientTogether", "1", 0)] as [(String, Any, Any)] {
            #expect(try marks(key, before, after) == expected, "\(key)")
        }

        expected = PreferenceChange()
        expected.databaseColumns = true
        #expect(try marks("COLUMNSDATABASE", [String: Any](), ["Patient name": 120]) == expected)

        expected = PreferenceChange()
        expected.listenerRestart = true
        for (key, before, after) in [("httpXMLRPCServer", "0", 1), ("httpXMLRPCServerPort", "8080", 8081), ("httpXMLRPCServerHTTPS", "0", true),
                                     ("httpWebServer", "0", 1), ("httpWebServerPort", "3333", "3334"), ("encryptedWebServer", nil, true),
                                     ("LISTENERCHECKINTERVAL", "15", 30), ("addNewIncomingFilesToDefaultDBOnly", nil, 1)] as [(String, Any?, Any?)] {
            #expect(try marks(key, before, after) == expected, "\(key)")
        }
    }

    @Test func aTextPreferenceOfAnotherTypeIsLoggedNotCompared() throws {
        // Seen for the first time: neither a change nor an error.
        var marks = try #require(change(["PET Blending CLUT": nil], ["PET Blending CLUT": "Hot Iron", "X": 1]))
        #expect(marks == PreferenceChange())
        marks = try #require(change(["PET Blending CLUT": 3, "DBDateFormat2": 1], ["PET Blending CLUT": "Hot Iron", "DBDateFormat2": "yyyy"]))
        #expect(marks.mistypedTextKeys == ["PET Blending CLUT", "DBDateFormat2"])
        #expect(!marks.petBlendingCLUT && !marks.databaseRefresh)
        // The text after the change is read as `string(forKey:)` reads it: a number is its text.
        marks = try #require(change(["DBDateFormat2": "1"], ["DBDateFormat2": 1]))
        #expect(!marks.databaseRefresh)
    }

    @Test func columnsThatWereNotATableAreAChange() throws {
        let marks = try #require(change(["COLUMNSDATABASE": nil], ["COLUMNSDATABASE": nil, "X": 1]))
        #expect(marks.databaseColumns)
    }
}
