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

/// The steps of a launch over preferences in memory: the user's own values
/// over the factory settings the application registers.
@Suite struct LaunchPreferenceMigrationsTests {
    private let factory = DefaultPreferences.defaults(in: testEnvironment, store: MemoryPreferences()) as? [String: Any] ?? [:]

    private func store(_ values: [String: Any] = [:], registered: [String: Any]? = nil, arguments: Set<String> = []) -> MemoryPreferences {
        MemoryPreferences(values, registered: registered ?? factory, arguments: arguments)
    }

    @Test func fixedValuesAreWrittenWhateverWasStored() {
        let preferences = store(["NSInitialToolTipDelay": 1500, "DontUseUndoQueueForROIs": true, "UndoQueueSize": 3])
        LaunchPreferenceMigrations.applyFixedValues(in: preferences)
        #expect(preferences.object(forKey: "NSInitialToolTipDelay") as? Int == 200)
        #expect(preferences.object(forKey: "DontUseUndoQueueForROIs") as? Bool == false)
        #expect(preferences.object(forKey: "UndoQueueSize") as? Int == 20)
    }

    @Test func autoCleanOfEarlierVersionsBecomesOneMode() {
        // Registered, the mode is always there: nothing is written.
        var preferences = store(["AUTOCLEANINGSPACEOPENED": true])
        LaunchPreferenceMigrations.migrateAutoClean(in: preferences)
        #expect(preferences.writes.isEmpty)
        for (produced, opened, mode) in [(false, false, 2), (true, true, 1), (false, true, 1), (true, false, 0)] {
            preferences = store(["AUTOCLEANINGSPACEPRODUCED": produced, "AUTOCLEANINGSPACEOPENED": opened], registered: [:])
            LaunchPreferenceMigrations.migrateAutoClean(in: preferences)
            #expect(preferences.object(forKey: "AutocleanSpaceMode") as? Int == mode)
            #expect((preferences.object(forKey: "AUTOCLEANINGSPACE") as? Bool) == (mode == 2 ? false : nil))
        }
    }

    @Test func theDefaultDatabaseLocationIsTheOneOpened() {
        let preferences = store(["DEFAULT_DATABASELOCATION": 1, "DEFAULT_DATABASELOCATIONURL": "/Volumes/Data/IsiX Data",
                                 "DATABASELOCATION": 0, "DATABASELOCATIONURL": "/elsewhere"])
        LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences)
        #expect(preferences.object(forKey: "DATABASELOCATION") as? Int == 1)
        #expect(preferences.object(forKey: "DATABASELOCATIONURL") as? String == "/Volumes/Data/IsiX Data")
        // No URL at all: the key is removed, as setting nil did.
        let bare = store(["DATABASELOCATIONURL": "/elsewhere"], registered: [:])
        LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: bare)
        #expect(bare.object(forKey: "DATABASELOCATIONURL") == nil)
    }

    @Test func sessionValues() {
        let preferences = store(["OSIEnvironmentActivated": true, "is12bitPluginAvailable": true, "ROITEXTNAMEONLY": true,
                                 "copyHideListenerError": true, "hideListenerError": false])
        LaunchPreferenceMigrations.applySessionValues(in: preferences, defaultDatabasePath: "(Current User Documents folder)")
        for key in ["OSIEnvironmentActivated", "is12bitPluginAvailable", "ROITEXTNAMEONLY"] {
            #expect(preferences.object(forKey: key) as? Bool == false, "\(key)")
        }
        #expect(preferences.object(forKey: "hideListenerError") as? Bool == true)
        #expect(preferences.object(forKey: "DefaultDatabasePath") as? String == "(Current User Documents folder)")
        #expect(preferences.object(forKey: "LP64bit") as? Bool == true)

        // Given at the launch, hideListenerError is the launch's: the kept value stays kept.
        let given = store(["copyHideListenerError": true, "hideListenerError": false], arguments: ["hideListenerError"])
        LaunchPreferenceMigrations.applySessionValues(in: given, defaultDatabasePath: "")
        #expect(given.object(forKey: "hideListenerError") as? Bool == false)
        // Nothing kept: nothing put back.
        let none = store(["hideListenerError": true])
        LaunchPreferenceMigrations.applySessionValues(in: none, defaultDatabasePath: "")
        #expect(none.object(forKey: "hideListenerError") as? Bool == true)
        #expect(!none.writes.contains("hideListenerError"))
    }

    @Test func endoscopyPresetsOverTheFactorySettings() throws {
        let preferences = store()
        LaunchPreferenceMigrations.addEndoscopyPresets(in: preferences)
        let shadings = try #require(preferences.object(forKey: "shadingsPresets") as? [[String: Any]])
        let names = shadings.compactMap { $0["name"] as? String }
        for name in ["Endoscopy", "Glossy Bone", "Glossy Vascular"] {
            #expect(names.filter { $0 == name }.count == 1, "\(name)")
        }
        // Written at every launch, as it always was.
        #expect(preferences.writes.contains("shadingsPresets"))
        let tables = try #require(preferences.object(forKey: "CLUT") as? [String: Any])
        let endoscopy = try #require(tables["Endoscopy"] as? [String: Any])
        #expect((endoscopy["Red"] as? [Int])?.first == 240)
        let windows = try #require(preferences.object(forKey: "WLWW3") as? [String: Any])
        #expect((windows["VR - Endoscopy"] as? [Float]) == [-300, 700])
    }

    @Test func endoscopyPresetsAreAddedOnce() throws {
        let shadings: [[String: Any]] = [["name": "Default", "ambient": "0.15"], ["name": "Glossy Bone", "ambient": "0.5"]]
        let preferences = store(["shadingsPresets": shadings, "CLUT": ["Other": ["Red": [1]]], "WLWW3": ["CT - Bone": [300, 1500]]],
                                registered: [:])
        LaunchPreferenceMigrations.addEndoscopyPresets(in: preferences)
        let written = try #require(preferences.object(forKey: "shadingsPresets") as? [[String: Any]])
        #expect(written.compactMap { $0["name"] as? String } == ["Default", "Glossy Bone", "Endoscopy", "Glossy Vascular"])
        // The user's own Glossy Bone is kept as it was.
        #expect(written[1]["ambient"] as? String == "0.5")
        #expect(written[2]["specularPower"] as? String == "50")
        let table = try #require((preferences.object(forKey: "CLUT") as? [String: Any])?["Endoscopy"] as? [String: Any])
        let red = try #require(table["Red"] as? [Int]), green = try #require(table["Green"] as? [Int])
        let blue = try #require(table["Blue"] as? [Int])
        #expect(red.count == 256 && red.first == 240 && red.last == 245)
        #expect(green.first == 187 && green.last == 120 && blue.first == 195 && blue.last == 128)
        #expect((table["Points"] as? [Int]) == [0, 255])
        #expect((table["Colors"] as? [[Float]]) == [[1, 1, 1], [0, 0, 0]])
        #expect((preferences.object(forKey: "CLUT") as? [String: Any])?["Other"] != nil)

        // A second launch: the table and the window stay as they are.
        let again = store(["shadingsPresets": written, "CLUT": preferences.object(forKey: "CLUT")!,
                           "WLWW3": preferences.object(forKey: "WLWW3")!], registered: [:])
        LaunchPreferenceMigrations.addEndoscopyPresets(in: again)
        #expect(again.writes == ["shadingsPresets"])
        #expect((again.object(forKey: "shadingsPresets") as? [Any])?.count == 4)
    }

    @Test func aWrongEndoscopyTableOfAnEarlierVersionIsMadeAgain() throws {
        let preferences = store(["CLUT": ["Endoscopy": ["Red": [0, 1], "Green": [0], "Blue": [0]]]], registered: [:])
        LaunchPreferenceMigrations.addEndoscopyPresets(in: preferences)
        let table = try #require((preferences.object(forKey: "CLUT") as? [String: Any])?["Endoscopy"] as? [String: Any])
        #expect((table["Red"] as? [Int])?.first == 240)
    }

    @Test func listsThatAreNotThereAreWrittenAsNotThere() {
        let preferences = store(registered: [:])
        LaunchPreferenceMigrations.addEndoscopyPresets(in: preferences)
        #expect(preferences.writes == ["shadingsPresets", "CLUT", "WLWW3"])
        for key in ["shadingsPresets", "CLUT", "WLWW3"] {
            #expect(preferences.object(forKey: key) == nil, "\(key)")
        }
    }

    @Test func temporarySourcesAndRepetitionsAreForgotten() throws {
        let sources: [[String: Any]] = [["Path": "/Volumes/Data/A", "Description": "A"], ["Path": "/private/var/folders/x/T/CD"],
                                        ["Path": "/Volumes/Data/A", "Description": "again"], ["Description": "no path"],
                                        ["Path": "/Users/me/B"]]
        let preferences = store(["localDatabasePaths": sources])
        let dropped = LaunchPreferenceMigrations.forgetTemporarySources(in: preferences) { $0.hasPrefix("/private/var/folders/") }
        #expect(dropped == ["/private/var/folders/x/T/CD"])
        let kept = try #require(preferences.object(forKey: "localDatabasePaths") as? [[String: Any]])
        #expect(kept.compactMap { $0["Path"] as? String } == ["/Volumes/Data/A", "/Users/me/B"])
        #expect(kept[0]["Description"] as? String == "A")

        // Nothing to forget: nothing written.
        let clean = store(["localDatabasePaths": [["Path": "/Users/me/B"]]])
        #expect(LaunchPreferenceMigrations.forgetTemporarySources(in: clean) { _ in false }.isEmpty)
        #expect(clean.writes.isEmpty)
        let absent = store()
        #expect(LaunchPreferenceMigrations.forgetTemporarySources(in: absent) { _ in true }.isEmpty)
        #expect(absent.writes.isEmpty)
    }

    @Test func timeZoneCopyModeAndLaunchCount() {
        let preferences = store(["COPYDATABASEMODE": "1"])
        LaunchPreferenceMigrations.recordTimeZone(in: preferences, secondsFromGMT: -10800)
        #expect(preferences.object(forKey: "timeZone") as? Int == -10800)
        LaunchPreferenceMigrations.recordTimeZone(in: preferences, secondsFromGMT: 3600)
        #expect(preferences.object(forKey: "timeZone") as? Int == -10800)

        LaunchPreferenceMigrations.migrateCopyToDatabaseMode(in: preferences)
        #expect(preferences.object(forKey: "COPYDATABASEMODE") as? Int == 2)
        let registered = store()
        LaunchPreferenceMigrations.migrateCopyToDatabaseMode(in: registered)
        #expect(registered.writes.isEmpty)

        // STARTCOUNT is registered as 1: the first launch counts 1 and writes 2.
        let fresh = store()
        #expect(LaunchPreferenceMigrations.countLaunch(in: fresh) == 1)
        #expect(fresh.object(forKey: "STARTCOUNT") as? Int == 2)
        #expect(LaunchPreferenceMigrations.countLaunch(in: fresh) == 2)
    }

    @Test func viewerValuesAreSwitches() {
        let preferences = store(["SAMESTUDY": 0])
        LaunchPreferenceMigrations.applyViewerValues(in: preferences)
        #expect(preferences.object(forKey: "SAMESTUDY") as? NSNumber == true as NSNumber)
        #expect(preferences.object(forKey: "hasMacOSXSnowLeopard") as? Bool == true)
    }

    @Test func doubleClickHotKeys() throws {
        // The factory list has them, and every action: nothing written.
        #expect(ViewerPreferences.factoryHotKeys()["dbl-click"] == LaunchPreferenceMigrations.HotKeyAction.fullScreen)
        #expect(ViewerPreferences.factoryHotKeys()["dbl-click + cmd"] == LaunchPreferenceMigrations.HotKeyAction.setKeyImage)
        let factorySettings = store()
        LaunchPreferenceMigrations.addDoubleClickHotKeys(in: factorySettings)
        #expect(factorySettings.writes.isEmpty)

        let earlier = store(["HOTKEYS": ["w": 13, "z": "15"]])
        LaunchPreferenceMigrations.addDoubleClickHotKeys(in: earlier)
        let hotKeys = try #require(earlier.object(forKey: "HOTKEYS") as? [String: Any])
        #expect(hotKeys.count == 5 && hotKeys["w"] as? Int == 13 && hotKeys["z"] as? String == "15")
        #expect(hotKeys["dbl-click"] as? Int == 50 && hotKeys["dbl-click + alt"] as? Int == 51 && hotKeys["dbl-click + cmd"] as? Int == 52)

        // One of the three already there, as a number or its text: the list is left alone.
        let assigned = store(["HOTKEYS": ["f": "51"]])
        LaunchPreferenceMigrations.addDoubleClickHotKeys(in: assigned)
        #expect(assigned.writes.isEmpty)
    }
}
