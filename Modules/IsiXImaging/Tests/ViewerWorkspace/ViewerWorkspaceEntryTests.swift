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

/// The saved layout written from `ViewerWorkspaceEntry` against the
/// dictionaries the viewers wrote before: each case is also built the former
/// way, one NSMutableDictionary per viewer with the same values under the same
/// keys, and both XML property lists must be the same bytes.
@Suite struct ViewerWorkspaceEntryTests {

    /// A generator with a fixed seed, so that a failure repeats.
    struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func randomFloat(_ g: inout Generator) -> Float {
        switch Int.random(in: 0..<6, using: &g) {
        case 0: return 0
        case 1: return Float(Int.random(in: -3000...3000, using: &g))
        case 2: return Float.random(in: -1e6...1e6, using: &g)
        case 3: return Float(bitPattern: UInt32.random(in: 0...UInt32.max, using: &g) & 0x7F7F_FFFF)
        case 4: return Float.random(in: 0.01...100, using: &g)
        default: return -Float.random(in: 0...1, using: &g)
        }
    }

    static func randomDouble(_ g: inout Generator) -> Double {
        Int.random(in: 0..<2, using: &g) == 0 ? Double(Float.random(in: -5000...5000, using: &g)) : Double.random(in: -1e5...1e5, using: &g)
    }

    static func randomText(_ g: inout Generator) -> String {
        let pieces = ["1.2.840", ".113619", ".2.55", "\\**\\", "é", "<&>", " ", "名", "12", "0"]
        return (0..<Int.random(in: 0...5, using: &g)).map { _ in pieces.randomElement(using: &g)! }.joined()
    }

    static func randomPreference(_ g: inout Generator) -> (ViewerWorkspaceEntry.StoredPreference, Any) {
        switch Int.random(in: 0..<4, using: &g) {
        case 0:
            let flag = Bool.random(using: &g)
            return (.boolean(flag), NSNumber(value: flag))
        case 1:
            let number = Int.random(in: -100...100, using: &g)
            return (.integer(number), NSNumber(value: number))
        case 2:
            let number = randomDouble(&g)
            return (.real(number), NSNumber(value: number))
        default:
            let text = randomText(&g)
            return (.text(text), text)
        }
    }

    /// An entry and the dictionary the former code built for the same viewer.
    static func randomCase(_ g: inout Generator) -> (ViewerWorkspaceEntry, NSDictionary) {
        let frame = CGRect(x: randomDouble(&g), y: randomDouble(&g), width: abs(randomDouble(&g)), height: abs(randomDouble(&g)))
        let screenIndex = Int.random(in: 0..<3, using: &g) == 0 ? UInt(bitPattern: NSNotFound) : UInt.random(in: 0...3, using: &g)
        let rows = Int.random(in: 1...8, using: &g), columns = Int.random(in: 1...8, using: &g)
        let index = Int32.random(in: -1...2000, using: &g)
        let wl = randomFloat(&g), ww = randomFloat(&g), scale = randomFloat(&g), rotation = randomFloat(&g)
        let x = randomDouble(&g), y = randomDouble(&g)
        let xFlipped = Bool.random(using: &g), yFlipped = Bool.random(using: &g)
        let study = randomText(&g)
        let series: String? = Bool.random(using: &g) ? randomText(&g) : nil
        let dicomUID: String? = Bool.random(using: &g) ? randomText(&g) : nil
        let is4D = Bool.random(using: &g)
        let tiling: (ViewerWorkspaceEntry.StoredPreference, Any)? = Bool.random(using: &g) ? randomPreference(&g) : nil
        let propagate = randomPreference(&g)
        let sync: Bool? = [true, false, nil].randomElement(using: &g)!
        let betweenStudies = Bool.random(using: &g), syncSeries = Bool.random(using: &g)
        let relative = randomFloat(&g)
        let date = Date(timeIntervalSinceReferenceDate: Double.random(in: 0...1e9, using: &g))
        let name = randomText(&g) + "x"

        let entry = ViewerWorkspaceEntry(
            name: name, windowPosition: ViewerWindowsState.windowPosition(frame), screen: NSStringFromRect(frame), screenIndex: screenIndex,
            rows: rows, columns: columns, index: index, windowLevel: wl, windowWidth: ww, scale: scale, x: x, y: y, rotation: rotation,
            xFlipped: xFlipped, yFlipped: yFlipped, studyInstanceUID: study, seriesInstanceUID: series, seriesDICOMUID: dicomUID, is4D: is4D,
            lastWindowsTilingRowsColumns: tiling?.0, propagateSettings: propagate.0, syncSettings: sync,
            syncButtonBehaviorIsBetweenStudies: betweenStudies, syncSeries: syncSeries, syncRelativeDiff: betweenStudies ? relative : nil, date: date)

        // The former code, key after key.
        let dict = NSMutableDictionary()
        dict.setObject(name as Any, forKey: "name" as NSString)
        dict.setObject(ViewerWindowsState.windowPosition(frame), forKey: "window position" as NSString)
        dict.setObject(NSStringFromRect(frame), forKey: "screen" as NSString)
        dict.setObject(NSNumber(value: screenIndex), forKey: "screenIndex" as NSString)
        dict.setObject(NSNumber(value: rows), forKey: "rows" as NSString)
        dict.setObject(NSNumber(value: columns), forKey: "columns" as NSString)
        dict.setObject(NSNumber(value: index), forKey: "index" as NSString)
        dict.setObject(NSNumber(value: wl), forKey: "wl" as NSString)
        dict.setObject(NSNumber(value: ww), forKey: "ww" as NSString)
        dict.setObject(NSNumber(value: scale), forKey: "scale" as NSString)
        dict.setObject(NSNumber(value: x), forKey: "x" as NSString)
        dict.setObject(NSNumber(value: y), forKey: "y" as NSString)
        dict.setObject(NSNumber(value: rotation), forKey: "rotation" as NSString)
        dict.setObject(NSNumber(value: xFlipped), forKey: "xFlipped" as NSString)
        dict.setObject(NSNumber(value: yFlipped), forKey: "yFlipped" as NSString)
        dict.setObject(study as Any, forKey: "studyInstanceUID" as NSString)
        if let series { dict.setObject(series, forKey: "seriesInstanceUID" as NSString) }
        if let dicomUID { dict.setObject(dicomUID, forKey: "seriesDICOMUID" as NSString) }
        dict.setObject(NSNumber(value: is4D), forKey: "4DData" as NSString)
        if let tiling { dict.setObject(tiling.1, forKey: "LastWindowsTilingRowsColumns" as NSString) }
        dict.setObject(propagate.1, forKey: "propagateSettings" as NSString)
        if let sync { dict.setObject(NSNumber(value: sync), forKey: "syncSettings" as NSString) }
        dict.setObject(NSNumber(value: betweenStudies), forKey: "SyncButtonBehaviorIsBetweenStudies" as NSString)
        dict.setObject(NSNumber(value: syncSeries), forKey: "SYNCSERIES" as NSString)
        if betweenStudies { dict.setObject(NSNumber(value: relative), forKey: "syncRelativeDiff" as NSString) }
        dict.setObject(date, forKey: "date" as NSString)
        return (entry, dict)
    }

    @Test func theXMLIsTheOneTheDictionariesWrote() throws {
        var g = Generator(state: 1704)
        for _ in 0..<4000 {
            let cases = (0..<Int.random(in: 0...4, using: &g)).map { _ in Self.randomCase(&g) }
            let former = try PropertyListSerialization.data(fromPropertyList: cases.map(\.1), format: .xml, options: 0)
            let written = try ViewerWorkspaceEntry.propertyList(cases.map(\.0))
            #expect(written == former)
            if written != former { return }
        }
    }

    @Test func aPartOfTheLayoutIsWhatTheDictionariesKept() throws {
        var g = Generator(state: 41)
        for _ in 0..<1000 {
            let cases = (0..<Int.random(in: 0...5, using: &g)).map { _ in Self.randomCase(&g) }
            let names = ["P1", "p\u{0131}1", "P\u{00ef}1", "pi1", "P2", ""]
            let patients = cases.map { _ in names.randomElement(using: &g)! }
            let patient: String? = Bool.random(using: &g) ? names.randomElement(using: &g)! : nil
            let former = ViewerWindowsState.entries(of: cases.map(\.1), patients: patients, patientUID: patient)
            let kept = ViewerWindowsState.entries(of: cases.map(\.0), patients: patients, patientUID: patient)
            #expect(try ViewerWorkspaceEntry.propertyList(kept) == PropertyListSerialization.data(fromPropertyList: former, format: .xml, options: 0))
        }
    }

    @Test func theEntriesComeBack() throws {
        var g = Generator(state: 7)
        for _ in 0..<200 {
            let entries = (0..<Int.random(in: 1...3, using: &g)).map { _ in Self.randomCase(&g).0 }
                .map { entry -> ViewerWorkspaceEntry in
                    var entry = entry
                    // A date keeps whole seconds in XML; a real number with no
                    // fraction may come back as an integer, which no switch stores.
                    entry.date = Date(timeIntervalSinceReferenceDate: entry.date.timeIntervalSinceReferenceDate.rounded(.down))
                    if case .real = entry.propagateSettings { entry.propagateSettings = .text("real") }
                    if case .real = entry.lastWindowsTilingRowsColumns { entry.lastWindowsTilingRowsColumns = .integer(22) }
                    return entry
                }
            let back = try ViewerWorkspaceEntry.entries(from: ViewerWorkspaceEntry.propertyList(entries))
            #expect(back.count == entries.count)
            for (one, other) in zip(back, entries) {
                #expect(one.name == other.name && one.windowPosition == other.windowPosition && one.screenIndex == other.screenIndex)
                #expect(one.windowLevel.bitPattern == other.windowLevel.bitPattern && one.scale.bitPattern == other.scale.bitPattern)
                #expect(one.x == other.x && one.y == other.y && one.xFlipped == other.xFlipped && one.yFlipped == other.yFlipped)
                #expect(one.seriesDICOMUID == other.seriesDICOMUID && one.syncSettings == other.syncSettings && one.date == other.date)
                #expect(one.propagateSettings == other.propagateSettings && one.lastWindowsTilingRowsColumns == other.lastWindowsTilingRowsColumns)
            }
        }
    }

    @Test func theStoredPreferenceKeepsItsKind() {
        #expect(ViewerWorkspaceEntry.StoredPreference(NSNumber(value: true)) == .boolean(true))
        #expect(ViewerWorkspaceEntry.StoredPreference(NSNumber(value: 22)) == .integer(22))
        #expect(ViewerWorkspaceEntry.StoredPreference(NSNumber(value: 1.5)) == .real(1.5))
        #expect(ViewerWorkspaceEntry.StoredPreference("12") == .text("12"))
        #expect(ViewerWorkspaceEntry.StoredPreference(Date()) == nil)
    }
}
