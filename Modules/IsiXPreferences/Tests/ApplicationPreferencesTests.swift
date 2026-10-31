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

/// The burn window read each option with the UserDefaults accessor of its key,
/// key by key; these are the keys and accessors it used, written as it wrote
/// them. The snapshot must give what they gave. Each accessor is read here
/// through the key of its type built from the name, whose conversion
/// PreferenceCatalogTests compares with the accessor itself: the registration
/// domain of UserDefaults is the process's, shared with that suite, so it is
/// not written here.
private enum PreviousBurnReading {
    static let names = (anonymized: "anonymizedBeforeBurning", destination: "burnDestination", encrypted: "EncryptCD",
                        compression: "Compression Mode for Burning", jpeg: "JPEGinsteadJPEG2000", weasis: "BurnWeasis",
                        html: "BurnHtml", reports: "copyReportsToCD", supplementary: "BurnSupplementaryFolder",
                        supplementaryPath: "SupplementaryBurnPath")

    static func bool(_ store: any PreferenceStore, _ name: String) -> Bool { store[PreferenceKey<Bool>(name)] }
    static func integer(_ store: any PreferenceStore, _ name: String) -> Int { store[PreferenceKey<Int>(name)] }
    static func string(_ store: any PreferenceStore, _ name: String) -> String? { store[PreferenceKey<String?>(name)] }

    static func options(_ store: any PreferenceStore) -> BurnOptions {
        BurnOptions(anonymized: bool(store, names.anonymized), destination: integer(store, names.destination),
                    encrypted: bool(store, names.encrypted), compressionMode: integer(store, names.compression),
                    jpegInsteadOfJPEG2000: bool(store, names.jpeg), includesWeasis: bool(store, names.weasis),
                    includesHTML: bool(store, names.html), copiesReports: bool(store, names.reports),
                    includesSupplementaryFolder: bool(store, names.supplementary),
                    supplementaryFolderPath: string(store, names.supplementaryPath))
    }

    /// `BurnHtml == true && anonymizedBeforeBurning == false`, and the same for the reports.
    static func addsHTML(_ store: any PreferenceStore) -> Bool {
        bool(store, names.html) == true && bool(store, names.anonymized) == false
    }

    static func addsReports(_ store: any PreferenceStore) -> Bool {
        bool(store, names.reports) == true && bool(store, names.anonymized) == false
    }

    /// The two checks that turned the supplementary folder off, then the path
    /// the medium copied from.
    static func supplementaryFolder(_ path: String?, exists: (String) -> Bool) -> String? {
        if ((path as NSString?)?.length ?? 0) <= 1 { return nil }
        if (path.map { exists(($0 as NSString).expandingTildeInPath) } ?? false) == false { return nil }
        return (path! as NSString).expandingTildeInPath
    }
}

@Suite(.serialized) struct ApplicationPreferencesTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]

    /// What a person may have stored: the forms the window's bindings write,
    /// the text forms of older versions, and numbers where a switch is read.
    private let userValues: [[String: Any]] = [
        [:],
        ["anonymizedBeforeBurning": true, "burnDestination": 2, "EncryptCD": true, "Compression Mode for Burning": 1,
         "JPEGinsteadJPEG2000": true, "BurnWeasis": true, "BurnHtml": false, "copyReportsToCD": true,
         "BurnSupplementaryFolder": true, "SupplementaryBurnPath": "~/Documents/Extra"],
        ["anonymizedBeforeBurning": "1", "burnDestination": "1", "EncryptCD": "YES", "Compression Mode for Burning": "2",
         "JPEGinsteadJPEG2000": "0", "BurnWeasis": "true", "BurnHtml": "1", "copyReportsToCD": "2",
         "BurnSupplementaryFolder": "1", "SupplementaryBurnPath": "/"],
        ["anonymizedBeforeBurning": 0, "burnDestination": 3.7, "EncryptCD": 2, "Compression Mode for Burning": " 1",
         "BurnHtml": 1, "copyReportsToCD": 1, "BurnSupplementaryFolder": 0, "SupplementaryBurnPath": 12],
    ]

    @Test func theBurnSnapshotGivesWhatTheWindowRead() {
        for values in userValues {
            let memory = MemoryPreferences(values, registered: factory)
            let previous = PreviousBurnReading.options(memory)
            #expect(BurnOptions(memory) == previous, "\(values)")
            #expect(BurnOptions(memory).addsHTML == PreviousBurnReading.addsHTML(memory), "\(values)")
            #expect(BurnOptions(memory).addsReports == PreviousBurnReading.addsReports(memory), "\(values)")
        }
        // Each option, changed alone over the factory settings, changes only its field.
        let factoryOptions = BurnOptions(MemoryPreferences(registered: factory))
        let changed: [(String, Bool, WritableKeyPath<BurnOptions, Bool>)] = [
            ("anonymizedBeforeBurning", true, \.anonymized), ("EncryptCD", true, \.encrypted),
            ("JPEGinsteadJPEG2000", true, \.jpegInsteadOfJPEG2000), ("BurnWeasis", true, \.includesWeasis),
            ("BurnHtml", false, \.includesHTML), ("copyReportsToCD", true, \.copiesReports),
            ("BurnSupplementaryFolder", true, \.includesSupplementaryFolder),
        ]
        for (name, value, field) in changed {
            var expected = factoryOptions
            expected[keyPath: field] = value
            #expect(BurnOptions(MemoryPreferences([name: value], registered: factory)) == expected, "\(name)")
        }
        var destination = factoryOptions
        destination.destination = 2
        #expect(BurnOptions(MemoryPreferences(["burnDestination": 2], registered: factory)) == destination)
        var compression = factoryOptions
        compression.compressionMode = 1
        #expect(BurnOptions(MemoryPreferences(["Compression Mode for Burning": 1], registered: factory)) == compression)
        var path = factoryOptions
        path.supplementaryFolderPath = "~/Extra"
        #expect(BurnOptions(MemoryPreferences(["SupplementaryBurnPath": "~/Extra"], registered: factory)) == path)
    }

    @Test func theFactoryBurnIsNotAnonymizedWithHTMLAndNoSupplementaryFolder() {
        let options = BurnOptions(MemoryPreferences(registered: factory))
        #expect(options == BurnOptions(anonymized: false, destination: 0, encrypted: false, compressionMode: 0,
                                       jpegInsteadOfJPEG2000: false, includesWeasis: false, includesHTML: true,
                                       copiesReports: false, includesSupplementaryFolder: false,
                                       supplementaryFolderPath: "/~Documents/FolderToBurn"))
        #expect(options.addsHTML)
    }

    @Test func theSupplementaryFolderIsUsableAsTheWindowJudgedIt() {
        let home = NSHomeDirectory()
        let existing: Set<String> = [home + "/Extra", "/Volumes/Data/Extra", "/~Documents/FolderToBurn"]
        let exists = { (path: String) in existing.contains(path) }
        for path in [nil, "", "/", "~", "x", "~/Extra", "~/Missing", "/Volumes/Data/Extra", "/Volumes/Data/Missing",
                     "/~Documents/FolderToBurn", "é"] as [String?] {
            var options = BurnOptions(MemoryPreferences(registered: factory))
            options.supplementaryFolderPath = path
            #expect(options.usableSupplementaryFolder(exists: exists) == PreviousBurnReading.supplementaryFolder(path, exists: exists),
                    "\(path ?? "nil")")
        }
    }

    @Test func theExportFolderFieldsReadAsThePanelReadThem() {
        let key = ApplicationPreferences.exportFolderFields
        let stored: [Any] = [["enabled": true, "patient": 1, "study": 2, "series": 3],
                             ["enabled": false, "patient": 0],
                             ["enabled": 1, "patient": "1", "study": 2.0, "series": 2.5],
                             ["enabled": "YES", "series": true],
                             [String: Any](), "not a table", 7]
        for value in stored {
            let memory = MemoryPreferences([key.name: value])
            // The panel's reading: dictionary(forKey:), which gives a stored
            // table and nil for anything else, `enabled` as a Boolean, the
            // fields as integers.
            let saved = memory.object(forKey: key.name) as? [String: Any]
            let expected = saved.map {
                ExportFolderFields(customized: $0["enabled"] as? Bool == true, patient: $0["patient"] as? Int,
                                   study: $0["study"] as? Int, series: $0["series"] as? Int)
            }
            #expect(memory[key] == expected, "\(value)")
        }
    }

    @Test func theAcceptedExportFolderFieldsAreWrittenAsThePanelWroteThem() {
        let key = ApplicationPreferences.exportFolderFields
        for (customized, patient, study, series) in [(true, 1, 2, 3), (false, 0, 0, 0)] {
            let fields = ExportFolderFields(customized: customized, patient: patient, study: study, series: series)
            let previous: [String: Any] = ["enabled": customized, "patient": patient, "study": study, "series": series]
            #expect(PropertyListValue(fields.namingOptions) == PropertyListValue(previous))
            let memory = MemoryPreferences()
            memory.set(fields, for: key)
            #expect(PropertyListValue(memory.object(forKey: key.name) ?? 0) == PropertyListValue(previous))
            #expect(memory[key] == fields)
            #expect(PropertyListValue(memory.object(forKey: key.name)!)
                    == .dictionary(["enabled": .boolean(customized), "patient": .integer(patient), "study": .integer(study),
                                    "series": .integer(series)]))
        }
    }

    @Test func theSplitViewsOfTheDatabaseWindowAreCatalogued() {
        let names = Set(DefaultPreferences.catalog.map(\.name))
        for name in ApplicationPreferences.splitViewNames {
            #expect(names.contains(name))
            #expect(ApplicationPreferences.splitViewFrames(name).registration == nil)
        }
        let memory = MemoryPreferences()
        let frames: [PropertyListValue] = [.string("{{0, 0}, {200, 400}}"), .string("{{201, 0}, {300, 400}}")]
        memory.set(frames, for: ApplicationPreferences.splitViewFrames("PluginSplit"))
        #expect(memory.object(forKey: "PluginSplit") as? [String] == ["{{0, 0}, {200, 400}}", "{{201, 0}, {300, 400}}"])
        #expect(memory[ApplicationPreferences.splitViewFrames("PluginSplit")] == frames)
    }

    @Test func keysWithNoRegisteredValueReadAsAbsent() {
        let memory = MemoryPreferences(registered: factory)
        let absent: [any CataloguedPreference] = [ApplicationPreferences.addDICOMDIRForExport, ApplicationPreferences.burnDestination,
                                                  ApplicationPreferences.burnWeasis, ApplicationPreferences.burnCompressionMode,
                                                  ApplicationPreferences.copyReportsToMedia,
                                                  ApplicationPreferences.dicomEditingWarningSuppressed,
                                                  ApplicationPreferences.exportFolderFields, ApplicationPreferences.encryptsBurnedMedia,
                                                  ApplicationPreferences.burnsJPEGInsteadOfJPEG2000,
                                                  ApplicationPreferences.hidesToolbarIfNotActive,
                                                  ApplicationPreferences.moveToApplicationsFolderAlertSuppressed,
                                                  ApplicationPreferences.osiEnvironmentActivated,
                                                  ApplicationPreferences.screenCaptureSeriesName]
        for key in absent {
            #expect(key.registration == nil, "\(key.name)")
            #expect(factory[key.name] == nil, "\(key.name)")
            #expect(memory.object(forKey: key.name) == nil, "\(key.name)")
        }
    }
}
