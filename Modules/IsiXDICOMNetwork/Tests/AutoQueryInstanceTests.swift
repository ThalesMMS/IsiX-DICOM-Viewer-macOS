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
import IsiXPreferences
@testable import IsiXDICOMNetwork

/// An instance as the Query window has always saved it: the preset of
/// -savePresetInDictionaryWithDICOMNodes: (numbers made as the window makes
/// them), the retrieve settings copied from the preferences, the name, and
/// the results the window keeps in it while it runs.
private func savedByTheWindow(name: String, refresh: Int32, retrieving: Bool) -> [String: Any] {
    [
        "instanceName": name,
        "DICOMNodes": ["pacs.example:104", "other.example:11112"],
        "DICOMNodesAETitle": ["PACS", "OTHER"],
        "searchFieldName": "DOE^J",
        "searchFieldRefPhysician": "",
        "searchInstitutionName": "",
        "searchStatus": NSNumber(value: 0 as Int),
        "searchFieldID": "",
        "searchFieldAN": "",
        "searchFieldStudyDescription": "",
        "searchFieldComments": "",
        "searchCustomField": "",
        "searchCustomFieldDICOM": "Accession Number",
        "dateFilterMatrix": NSNumber(value: Int32(1)),
        "birthdateFilterMatrix": NSNumber(value: Int32(0)),
        "modalityStrings": ["CT", "MR"],
        "PatientModeMatrix": NSNumber(value: Int32(0)),
        "fromDate": NSNumber(value: 783_993_600.0),
        "toDate": NSNumber(value: 784_080_000.5),
        "searchBirth": NSNumber(value: -31_622_400.0),
        "autoRefreshQueryResults": NSNumber(value: refresh),
        "autoRetrieving": NSNumber(value: retrieving),
        "NumberOfPreviousStudyToRetrieve": NSNumber(value: 2 as Int),
        "retrieveSameModality": NSNumber(value: true),
        "retrieveSameDescription": NSNumber(value: false),
        "resultArray": [NSObject(), NSObject()],
    ]
}

/// The kind of property-list value, so that a boolean that came back as an
/// integer (or the reverse) is seen.
private func kind(_ value: Any) -> String {
    if let number = value as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return "boolean" }
        return CFNumberIsFloatType(number) ? "real" : "integer"
    }
    switch value {
    case is String: return "string"
    case is [Any]: return "array"
    case is [String: Any]: return "dictionary"
    default: return String(describing: type(of: value))
    }
}

private func sameValue(_ a: Any, _ b: Any) -> Bool {
    (a as AnyObject).isEqual(b) && kind(a) == kind(b)
}

/// Preferences in memory: the tests touch no preferences domain.
private func preferences() -> MemoryPreferences {
    MemoryPreferences()
}

/// The instances of the automatic query, as a Codable and Sendable value kept
/// in the preferences with the keys of today.
struct AutoQueryInstanceTests {

    @Test func todaysDictionaryComesBackWithTheSameKeysValuesAndTypes() throws {
        let saved = savedByTheWindow(name: "CT today", refresh: -30, retrieving: true)
        let instance = try #require(AutoQueryInstance(propertyList: saved))
        let written = instance.propertyList

        var expected = saved
        expected["resultArray"] = nil
        #expect(Set(written.keys) == Set(expected.keys))
        for (key, value) in expected {
            #expect(written[key].map { sameValue($0, value) } == true, "\(key) changed: \(String(describing: written[key]))")
        }
        #expect(Set(AutoQueryInstance.Key.allCases.map(\.rawValue)) == Set(expected.keys))
    }

    @Test func theTypedValuesReadAsTheWindowReadsThem() throws {
        var instance = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "A", refresh: -30, retrieving: true)))
        #expect(instance.name == "A")
        #expect(instance.refreshSetting == -30 && instance.refreshInterval == 30)
        #expect(instance.autoRetrieving && instance.retrieveSameModality && !instance.retrieveSameDescription)
        #expect(instance.numberOfPreviousStudiesToRetrieve == 2)
        #expect(instance.dicomNodes == ["pacs.example:104", "other.example:11112"])
        #expect(instance.dicomNodesAETitles == ["PACS", "OTHER"])
        #expect(instance.modalities == ["CT", "MR"] && instance.dateFilter == 1 && instance.patientMode == 0)

        instance.refreshSetting = 5
        #expect(instance.refreshInterval == 300)
        instance.refreshSetting = 0
        #expect(instance.refreshInterval == nil)

        // A number kept as text, as older versions and hand edits left them.
        let text = try #require(AutoQueryInstance(propertyList: ["autoRefreshQueryResults": "-12", "autoRetrieving": "YES",
                                                                 "NumberOfPreviousStudyToRetrieve": 3.0]))
        #expect(text.refreshInterval == 12 && text.autoRetrieving && text.numberOfPreviousStudiesToRetrieve == 3)
        #expect(sameValue(text.propertyList["autoRefreshQueryResults"]!, "-12"))
        #expect(AutoQueryInstance(propertyList: "not a dictionary") == nil)
        #expect(AutoQueryInstance(values: [:]).refreshInterval == nil)
    }

    @Test func anAbsurdSavedIntervalIsKeptWithinADay() async throws {
        // Saved in the instance's own dictionary, not through the window's
        // preference: the minutes of Int.max and the seconds of Int.min do not
        // fit an Int, and used to trap.
        let longest = try #require(AutoQueryInstance(propertyList: ["instanceName": "max", "autoRefreshQueryResults": Int.max]))
        let shortest = try #require(AutoQueryInstance(propertyList: ["instanceName": "min", "autoRefreshQueryResults": Int.min]))
        #expect(longest.refreshSetting == Int.max && longest.refreshInterval == 86_400)
        #expect(shortest.refreshSetting == Int.min && shortest.refreshInterval == 86_400)
        #expect(AutoQueryInstance.seconds(ofRefreshSetting: 1_441) == 86_400)
        #expect(AutoQueryInstance.seconds(ofRefreshSetting: -86_401) == 86_400)

        // The scheduler counts them down like any other instance.
        let scheduler = AutoQueryScheduler(querying: StandInQueries(), retrieving: StandInRetrieve(),
                                           localStudies: StandInLocalStudies(files: [:]),
                                           rules: { AutoRetrieveRules(maximumStudies: 10) },
                                           now: { Date(timeIntervalSinceReferenceDate: 0) }, tickInterval: .seconds(1))
        await scheduler.setInstances([longest, shortest])
        #expect(await scheduler.secondsRemaining(for: longest.id) == 86_400)
        #expect(await scheduler.secondsRemaining(for: shortest.id) == 86_400)
    }

    @Test func aKeyThisVersionDoesNotKnowIsKept() throws {
        let instance = try #require(AutoQueryInstance(propertyList: ["instanceName": "B", "modalityFilterMatrixString": "1 2 3 0",
                                                                     "futureSetting": ["a": [1, 2.5, true]]]))
        let written = instance.propertyList
        #expect(written["modalityFilterMatrixString"] as? String == "1 2 3 0")
        let future = try #require(written["futureSetting"] as? [String: Any])
        let list = try #require(future["a"] as? [Any])
        #expect(list.count == 3 && kind(list[0]) == "integer" && kind(list[1]) == "real" && kind(list[2]) == "boolean")
    }

    @Test func savingWritesEveryInstanceUnderTodaysKeyWithoutResults() throws {
        let defaults = preferences()
        let first = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "A", refresh: -30, retrieving: true)))
        let second = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "B", refresh: 5, retrieving: false)))
        AutoQueryInstanceStore.save([first, second], to: defaults)

        let stored = try #require(defaults.object(forKey: "savedAutoDICOMQuerySettingsArray") as? [[String: Any]])
        #expect(stored.map { $0["instanceName"] as? String } == ["A", "B"])
        #expect(stored.allSatisfy { $0["resultArray"] == nil })
        #expect(kind(stored[0]["autoRetrieving"]!) == "boolean" && kind(stored[1]["autoRefreshQueryResults"]!) == "integer")

        let loaded = AutoQueryInstanceStore.load(from: defaults, defaultName: "Default Instance")
        #expect(loaded.map(\.values) == [first.values, second.values])
        #expect(Set(loaded.map(\.id)).count == 2)
    }

    @Test func theFormerSingleInstanceJoinsTheListOnce() throws {
        let defaults = preferences()
        let existing = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "A", refresh: 1, retrieving: false)))
        AutoQueryInstanceStore.save([existing], to: defaults)
        var former = savedByTheWindow(name: "ignored", refresh: 2, retrieving: false)
        former["instanceName"] = nil
        former["resultArray"] = nil
        defaults.set(former, forKey: "savedAutoDICOMQuerySettings")

        let loaded = AutoQueryInstanceStore.load(from: defaults, defaultName: "Default Instance")
        #expect(loaded.map(\.name) == ["A", "Default Instance"])
        #expect(defaults.object(forKey: "savedAutoDICOMQuerySettings") == nil)
        #expect((defaults.object(forKey: "savedAutoDICOMQuerySettingsArray") as? [Any] ?? []).count == 2)
        #expect(AutoQueryInstanceStore.load(from: defaults, defaultName: "Default Instance").count == 2)
        #expect(AutoQueryInstanceStore.load(from: preferences(), defaultName: "Default Instance").isEmpty)
    }

    @Test func addingTheWindowsFiltersKeepsTheIdentityAndWhatTheyLack() throws {
        let instance = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "A", refresh: -30, retrieving: true)))
        let saved = instance.adding(["searchFieldName": "ROE^R", "autoRefreshQueryResults": NSNumber(value: Int32(10)),
                                     "resultArray": [NSObject()]])
        #expect(saved.id == instance.id)
        #expect(saved[.searchFieldName]?.stringValue == "ROE^R" && saved.refreshInterval == 600)
        #expect(saved.name == "A" && saved.autoRetrieving)
        #expect(saved.values[AutoQueryInstance.resultsKey] == nil)
    }

    @Test func itEncodesWithTodaysKeysInAPropertyListAndInJSON() throws {
        let instance = try #require(AutoQueryInstance(propertyList: savedByTheWindow(name: "A", refresh: -30, retrieving: true)))

        // An encoder writes a whole real number as an integer, which reads the
        // same; everything else keeps its type.
        func same(_ a: AutoQueryInstance) -> Bool {
            a.values.keys.sorted() == instance.values.keys.sorted() && a.values.allSatisfy { key, value in
                guard let original = instance.values[key] else { return false }
                if case .real(let real) = original, case .integer(let integer) = value { return real == Double(integer) }
                return original == value
            }
        }

        let plist = try PropertyListEncoder().encode(instance)
        let decoded = try PropertyListDecoder().decode(AutoQueryInstance.self, from: plist)
        #expect(same(decoded))
        #expect(decoded.autoRetrieving && decoded.refreshSetting == -30 && decoded[.toDate] == .real(784_080_000.5))
        let object = try #require(try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        #expect(Set(object.keys) == Set(instance.values.keys))
        #expect(kind(object["autoRetrieving"]!) == "boolean" && kind(object["autoRefreshQueryResults"]!) == "integer")

        let json = try JSONEncoder().encode(instance)
        #expect(same(try JSONDecoder().decode(AutoQueryInstance.self, from: json)))

        let other: PropertyListValue = .dictionary(["when": .date(Date(timeIntervalSinceReferenceDate: 12)), "bytes": .data(Data([1, 2]))])
        let otherPlist = try PropertyListEncoder().encode(["v": other])
        #expect(try PropertyListDecoder().decode([String: PropertyListValue].self, from: otherPlist)["v"] == other)
    }

    // MARK: The dates a run queries with

    private static let utc = TimeZone(identifier: "UTC")!

    private static func day(_ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    /// An instance as the window saves it, with its date choice and dates.
    private static func instance(_ name: String, choice: Int32, from: Date?, to: Date?) -> AutoQueryInstance {
        var saved = savedByTheWindow(name: name, refresh: -30, retrieving: false)
        saved["dateFilterMatrix"] = NSNumber(value: choice)
        saved["fromDate"] = from.map { NSNumber(value: $0.timeIntervalSinceReferenceDate) }
        saved["toDate"] = to.map { NSNumber(value: $0.timeIntervalSinceReferenceDate) }
        return AutoQueryInstance(propertyList: saved)!
    }

    /// The StudyDate the C-FIND of a run sends.
    private static func studyDate(_ filters: QueryWindowFilters, now: Date) -> String? {
        filters.query(settings: QueryWindowQuerySettings(allowsStudyDate: true), customFieldKeyword: nil, now: now,
                      timeZone: utc).value(of: "StudyDate")
    }

    @Test func eachInstanceNotShownQueriesWithItsOwnSavedDates() {
        let now = Self.day(10, 30)
        let window = (from: Self.day(10, 28), to: Self.day(10, 29))
        let first = Self.instance("A", choice: QueryDateFilter.between, from: Self.day(10, 1), to: Self.day(10, 3))
        let second = Self.instance("B", choice: QueryDateFilter.between, from: Self.day(9, 12), to: Self.day(9, 10))

        // Neither is the one shown: each asks for its own range.
        #expect(Self.studyDate(first.queryFilters(windowDates: window, shown: false), now: now) == "20261001-20261003")
        #expect(Self.studyDate(second.queryFilters(windowDates: window, shown: false), now: now) == "20260910-20260912")
        // The one shown asks for the window's pickers, which saving it wrote into it.
        #expect(Self.studyDate(first.queryFilters(windowDates: window, shown: true), now: now) == "20261028-20261029")

        // "On" and "after" read the first date the same way.
        let on = Self.instance("C", choice: QueryDateFilter.on, from: Self.day(8, 15), to: nil)
        #expect(Self.studyDate(on.queryFilters(windowDates: window, shown: false), now: now) == "20260815-20260815")
        let after = Self.instance("D", choice: QueryDateFilter.after, from: Self.day(7, 4), to: nil)
        #expect(Self.studyDate(after.queryFilters(windowDates: window, shown: false), now: now) == "20260704-20261030")
    }

    @Test func relativeChoicesAndMissingDatesFollowTheRun() {
        let window = (from: Self.day(10, 28), to: Self.day(10, 29))
        // A relative choice ignores the saved dates and counts from the run.
        let recent = Self.instance("E", choice: QueryDateFilter.last7Days, from: Self.day(1, 1), to: Self.day(1, 2))
        #expect(Self.studyDate(recent.queryFilters(windowDates: window, shown: false), now: Self.day(10, 30)) == "20261023-20261030")
        #expect(Self.studyDate(recent.queryFilters(windowDates: window, shown: false), now: Self.day(11, 5)) == "20261029-20261105")
        let today = Self.instance("F", choice: QueryDateFilter.today, from: Self.day(1, 1), to: Self.day(1, 2))
        #expect(Self.studyDate(today.queryFilters(windowDates: window, shown: false), now: Self.day(10, 30)) == "20261030-20261030")

        // An instance that never saved its dates takes the window's, as before.
        let unsaved = Self.instance("G", choice: QueryDateFilter.between, from: nil, to: nil)
        #expect(Self.studyDate(unsaved.queryFilters(windowDates: window, shown: false), now: Self.day(10, 30)) == "20261028-20261029")
    }
}
