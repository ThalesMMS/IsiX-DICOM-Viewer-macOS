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

/// The local sources, the location of the database and the fields of the
/// anonymization, read as types and written back in the form the previous
/// revision stored: the dictionaries the Locations pane's table and the browser
/// wrote, `set(1, forKey:)` and `set(path, forKey:)` of first use, and the
/// NSDictionary of tag names and the NSArray of tag texts the anonymization
/// panel wrote, with values of every kind its fields give.
@Suite struct DatabasePreferencesTests {
    /// Reads `stored` under `key`, writes the value back into an empty store
    /// and checks that the property list is the one stored.
    private func roundTrip<Value: PreferenceValue>(_ key: PreferenceKey<Value>, _ stored: Any) throws -> Value {
        let value = MemoryPreferences([key.name: stored])[key]
        let written = MemoryPreferences()
        written.set(value, for: key)
        #expect(PropertyListValue(try #require(written.object(forKey: key.name))) == PropertyListValue(stored), "\(key.name)")
        return value
    }

    /// The value encoded with PropertyListEncoder is the property list stored,
    /// and decodes to the same value.
    private func codable<Value: PropertyListRepresentable>(_ value: Value) throws {
        let data = try PropertyListEncoder().encode([value])
        let decoded = try PropertyListDecoder().decode([Value].self, from: data)
        #expect(decoded == [value])
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [Any]
        #expect(object.flatMap { $0.first }.flatMap(PropertyListValue.init) == value.propertyList)
    }

    @Test func localSourcesKeepTheirForm() throws {
        let stored: [Any] = [
            ["Path": "/Volumes/Archive", "Description": "Archive", "Activated": true, "FederatedSearch": NSNumber(value: 1)] as [String: Any],
            ["Path": "/Users/reader/Teaching", "Description": "Teaching"],
            ["Description": "No path"],
            "not a source",
        ]
        let sources = try #require(try roundTrip(DatabasePreferences.localDatabaseSources, stored))
        #expect(sources.paths == ["/Volumes/Archive", "/Users/reader/Teaching"])
        #expect(sources.sources.map(\.name) == ["Archive", "Teaching", "No path"])
        try codable(sources)
        #expect(LocalDatabaseSource(path: "/a", name: "A").propertyList == .dictionary(["Path": .string("/a"), "Description": .string("A")]))
        #expect(MemoryPreferences(["localDatabasePaths": "text"])[DatabasePreferences.localDatabaseSources] == nil)
    }

    @Test func theLocationIsReadAndWrittenAsTwoKeys() throws {
        // As first use stored a chosen folder: the text first, then the integer.
        let previous = MemoryPreferences()
        previous.set("/Volumes/Data", forKey: "DEFAULT_DATABASELOCATIONURL")
        previous.set(1, forKey: "DEFAULT_DATABASELOCATION")
        let location = previous[DatabasePreferences.defaultLocation]
        #expect(location == .folder("/Volumes/Data") && location.usesFolder)

        let written = MemoryPreferences()
        written.set(location, for: DatabasePreferences.defaultLocation)
        #expect(written.writes == ["DEFAULT_DATABASELOCATIONURL", "DEFAULT_DATABASELOCATION"])
        for name in ["DEFAULT_DATABASELOCATIONURL", "DEFAULT_DATABASELOCATION"] {
            #expect(PropertyListValue(try #require(written.object(forKey: name))) == PropertyListValue(try #require(previous.object(forKey: name))))
        }

        // The copy of the chosen location into the one opened, as the move
        // out of iCloud Drive did it, and a location with no folder.
        written.set(written[DatabasePreferences.defaultLocation], for: DatabasePreferences.location)
        #expect(written[DatabasePreferences.location] == location)
        written.set(DatabaseLocationSetting(mode: 0, folder: nil), for: DatabasePreferences.location)
        #expect(written.object(forKey: "DATABASELOCATIONURL") == nil)
        #expect(written[DatabasePreferences.location] == DatabaseLocationSetting(mode: 0, folder: nil))

        // Text stored by hand reads as integer(forKey:) and string(forKey:) read it.
        let typed = MemoryPreferences(["DATABASELOCATION": "1", "DATABASELOCATIONURL": "/x"])
        #expect(typed[DatabasePreferences.location] == .folder("/x"))
        let arguments = MemoryPreferences(arguments: ["DEFAULT_DATABASELOCATIONURL"])
        #expect(DatabasePreferences.defaultLocation.isGivenAsLaunchArgument(in: arguments))
        #expect(!DatabasePreferences.location.isGivenAsLaunchArgument(in: arguments))

        let data = try PropertyListEncoder().encode(location)
        #expect(try PropertyListDecoder().decode(DatabaseLocationSetting.self, from: data) == location)
    }

    @Test func anonymizationFieldsKeepTheirForm() throws {
        let birth = Date(timeIntervalSinceReferenceDate: 0)
        let values: [String: Any] = ["PatientsName": "ANONYMOUS", "PatientsBirthDate": birth, "PatientsWeight": NSNumber(value: 70),
                                     "PatientID": "", "0009,0010": "kept"]
        let fields = try #require(try roundTrip(DatabasePreferences.anonymizationFields, values))
        #expect(fields.values["PatientsName"] == .string("ANONYMOUS"))
        #expect(fields.values["PatientsBirthDate"] == .date(birth))
        #expect(fields.values["PatientID"] == .string(""))
        try codable(fields)

        let list = try #require(try roundTrip(DatabasePreferences.anonymizationFieldList, ["0010,0010", "0010,0030", NSNumber(value: 3)]))
        #expect(list.tags == ["0010,0010", "0010,0030"])
        #expect(AnonymizationFieldList(["0010,0010"]).propertyList == .array([.string("0010,0010")]))
        try codable(list)

        // A panel a plugin opens with a key of its own.
        #expect(DatabasePreferences.anonymizationFields(forPanel: "PluginFields").name == "PluginFields")
        #expect(DatabasePreferences.anonymizationFieldList(forPanel: "PluginFields").name == "PluginFieldsAll")
        #expect(DatabasePreferences.anonymizationFieldList.name == "AnonymizationFieldsAll")
    }

    @Test func templatesKeepTheirFormAndTheOthers() throws {
        let stored: [String: Any] = ["Trial": ["PatientsName": "TRIAL-01", "PatientID": ""] as [String: Any],
                                     "Teaching": ["PatientsName": "", "StudyDate": Date(timeIntervalSinceReferenceDate: 86_400)] as [String: Any],
                                     "Broken": "not a template"]
        let templates = try #require(try roundTrip(DatabasePreferences.anonymizationTemplates, stored))
        #expect(Set(templates.names) == ["Trial", "Teaching", "Broken"])
        #expect(Set(templates.templates.keys) == ["Trial", "Teaching"])
        #expect(templates["Trial"]?.values["PatientsName"] == .string("TRIAL-01"))
        #expect(templates["Broken"] == nil)
        try codable(templates)

        let saved = templates.setting(AnonymizationFieldValues(["PatientsName": .string("NEW")]), named: "Trial")
        #expect(saved["Trial"]?.values == ["PatientsName": .string("NEW")])
        #expect(saved.propertyList.dictionaryValue?["Broken"] == .string("not a template"))
        let removed = saved.removing(named: "Teaching")
        #expect(Set(removed.names) == ["Trial", "Broken"])
        #expect(AnonymizationTemplates().names.isEmpty)
    }

    @Test func theKeysOfTheAreaAreInTheCatalog() {
        let names = Set(DatabasePreferences.catalog.map(\.name))
        for name in ["localDatabasePaths", "DATABASELOCATION", "DATABASELOCATIONURL", "DEFAULT_DATABASELOCATION",
                     "DEFAULT_DATABASELOCATIONURL", "AnonymizationFields", "AnonymizationFieldsAll", "anonymizeTemplate",
                     "DatabaseLocationChoiceCompleted", "DatabaseLocationChoicePending", "AdoptedHorosDataDirectories",
                     "KeptHorosDataDirectories", "ICLOUD_DRIVE_SYNC_RISK_USER_IGNORED", "DATABASEVERSION", "REPORTSPLUGIN",
                     "clearSearchAndTimeIntervalWhenSelectingAlbum"] {
            #expect(names.contains(name), "\(name)")
        }
        // No registered value: absent reads as false, 0 or nil.
        let empty = MemoryPreferences()
        #expect(empty[DatabasePreferences.erasesEntireDatabaseAtStartup] == false)
        #expect(empty[DatabasePreferences.sortSeriesBySliceLocation] == 0)
        #expect(empty[DatabasePreferences.localDatabaseSources] == nil)
        #expect(DatabasePreferences.localDatabaseSources.registration == nil)
        #expect(empty[DatabasePreferences.reportsPlugin] == nil)
        #expect(empty[DatabasePreferences.clearsSearchWhenSelectingAlbum] == false)
        // The report plugin is the title of the pane's menu item, written as text.
        #expect(MemoryPreferences(["REPORTSPLUGIN": "Report Plugin"])[DatabasePreferences.reportsPlugin] == "Report Plugin")
    }
}
