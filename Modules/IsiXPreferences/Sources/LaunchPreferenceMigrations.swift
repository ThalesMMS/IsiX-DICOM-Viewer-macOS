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

/// What each launch writes into the preferences before anything reads them:
/// the values it always states, the forms earlier versions stored that it
/// brings up to date, and the presets it adds to lists the user may have
/// changed. Each step is one function, called by the application where the
/// launch always made it; each writes in the form the former code wrote, so
/// the preference file of a launch is the one the former launch left.
public enum LaunchPreferenceMigrations {
    // MARK: Registering the defaults

    /// What the application states before anything else reads its
    /// preferences, whatever was stored: AppKit's delay before a tool tip
    /// shows, and the undo of the ROIs with its depth.
    public static func applyFixedValues(in store: any PreferenceStore) {
        store.set(200, for: ApplicationPreferences.initialToolTipDelay)
        store.set(false, for: ReconstructionPreferences.doesNotUseUndoQueueForROIs)
        store.set(20, for: ReconstructionPreferences.undoQueueSize)
    }

    /// The automatic cleaning by free space: the switches of the earlier
    /// versions (the oldest studies, the oldest unopened ones) are one mode,
    /// written once. Off when neither was on.
    public static func migrateAutoClean(in store: any PreferenceStore) {
        guard store.object(forKey: DatabasePreferences.autocleanSpaceMode.name) == nil else { return }
        let cleansOldest = store[DatabasePreferences.formerAutoCleanBySpaceProduced]
        let cleansOldestUnopened = store[DatabasePreferences.formerAutoCleanBySpaceOpened]
        if !cleansOldest && !cleansOldestUnopened {
            store.set(false, for: DatabasePreferences.autoCleanBySpace)
            store.set(2, for: DatabasePreferences.autocleanSpaceMode)
        } else if cleansOldestUnopened {
            store.set(1, for: DatabasePreferences.autocleanSpaceMode)
        } else {
            store.set(0, for: DatabasePreferences.autocleanSpaceMode)
        }
    }

    /// The database opened is the default one: its kind and, for a database
    /// of its own folder, its URL, none when there is none.
    public static func copyDefaultDatabaseLocation(in store: any PreferenceStore) {
        store.set(store[DatabasePreferences.defaultDatabaseLocation], for: DatabasePreferences.databaseLocation)
        store.set(store[DatabasePreferences.defaultDatabaseLocationURL], for: DatabasePreferences.databaseLocationURL)
    }

    /// What every launch starts from: no plugin environment yet, no 12-bit
    /// display plugin, ROI labels with their measurements, the hiding of the
    /// listener's errors as the user had it before an abort of the incoming
    /// transfers hid them (unless the launch was given the key), the name the
    /// Database pane shows for the default location, and 64 bits.
    public static func applySessionValues(in store: any PreferenceStore, defaultDatabasePath: String) {
        store.set(false, for: ApplicationPreferences.osiEnvironmentActivated)
        store.set(false, for: ApplicationPreferences.is12BitPluginAvailable)
        store.set(false, for: ViewerPreferences.roiTextNameOnly)
        if !store.isGivenAsLaunchArgument(NetworkPreferences.hidesListenerErrors)
            && store.object(forKey: NetworkPreferences.savedHidesListenerErrors.name) != nil {
            store.set(store[NetworkPreferences.savedHidesListenerErrors], for: NetworkPreferences.hidesListenerErrors)
        }
        store.set(defaultDatabasePath, for: DatabasePreferences.defaultDatabasePathDescription)
        store.set(true, for: ApplicationPreferences.is64Bit)
    }

    // MARK: After the plugins

    /// The presets of the virtual endoscopy, added to lists the user may have
    /// changed: the Endoscopy, Glossy Bone and Glossy Vascular shadings, the
    /// Endoscopy colour table (made again when an earlier version stored a
    /// wrong one, whose red did not start at 240) and its window. The shading
    /// list is written at every launch, as it always was.
    public static func addEndoscopyPresets(in store: any PreferenceStore) {
        let shadingsKey = ImagePresetPreferences.shadingPresets.name
        var shadings = store.object(forKey: shadingsKey) as? [Any]
        for shading in endoscopyShadings {
            let name = shading["name"]
            let exists = shadings?.contains { (($0 as? [String: Any])?["name"] as? String) == name } ?? false
            if !exists { shadings?.append(shading) }
        }
        store.set(shadings, forKey: shadingsKey)

        let tablesKey = ImagePresetPreferences.colourTables.name
        let tables = store.object(forKey: tablesKey) as? [String: Any]
        let endoscopy = tables?["Endoscopy"] as? [String: Any]
        if endoscopy == nil || integer32((endoscopy?["Red"] as? [Any])?.first) != 240 {
            var updated = tables
            updated?["Endoscopy"] = endoscopyColourTable()
            store.set(updated, forKey: tablesKey)
        }

        let windowsKey = ImagePresetPreferences.windowLevelPresets.name
        let windows = store.object(forKey: windowsKey) as? [String: Any]
        if windows?["VR - Endoscopy"] == nil {
            var updated = windows
            updated?["VR - Endoscopy"] = [Float(-300), Float(700)]
            store.set(updated, forKey: windowsKey)
        }
    }

    /// The shadings of the virtual endoscopy, each written as text.
    static let endoscopyShadings: [[String: String]] = [
        ["name": "Endoscopy", "ambient": "0.12", "diffuse": "0.64", "specular": "0.73", "specularPower": "50"],
        ["name": "Glossy Bone", "ambient": "0.15", "diffuse": "0.24", "specular": "1.17", "specularPower": "6.98"],
        ["name": "Glossy Vascular", "ambient": "0.15", "diffuse": "0.28", "specular": "1.42", "specularPower": "50"],
    ]

    /// The Endoscopy colour table: red from 240, green from 187 and blue from
    /// 195, each along its own slope over the 256 entries, with its two points
    /// from white to black.
    static func endoscopyColourTable() -> [String: Any] {
        let entries = 0..<256
        return [
            "Red": entries.map { Int(240 + Double($0) * 0.02) },
            "Green": entries.map { Int(187 - Double($0) * 0.26) },
            "Blue": entries.map { Int(195 - Double($0) * 0.26) },
            "Colors": [[Float(1), Float(1), Float(1)], [Float(0), Float(0), Float(0)]],
            "Points": [0, 255],
        ]
    }

    // MARK: As the launch finishes

    /// The remembered sources that are worth keeping: the permanent ones,
    /// without repetitions, rewritten when anything was left out. A source in
    /// a place the system empties on its own (a CD's database copied to a
    /// temporary folder) is not a database to come back to. Answers the paths
    /// left out for being temporary, so that the log can say so.
    public static func forgetTemporarySources(in store: any PreferenceStore,
                                              isTemporary: (String) -> Bool) -> [String] {
        let key = DatabasePreferences.localDatabaseSources.name
        let stored = store.object(forKey: key)
        let entries = (stored as? [[String: Any]]) ?? []
        var kept: [[String: Any]] = []
        var seen = Set<String>()
        for entry in entries {
            guard let path = entry["Path"] as? String, !isTemporary(path), !seen.contains(path) else { continue }
            seen.insert(path)
            kept.append(entry)
        }
        guard kept.count != ((stored as? [Any])?.count ?? 0) else { return [] }
        store.set(kept, forKey: key)
        return entries.compactMap { $0["Path"] as? String }.filter(isTemporary)
    }

    /// The offset from GMT of the first launch, kept.
    public static func recordTimeZone(in store: any PreferenceStore, secondsFromGMT: Int) {
        guard store.object(forKey: ApplicationPreferences.timeZone.name) == nil else { return }
        store.set(secondsFromGMT, for: ApplicationPreferences.timeZone)
    }

    /// The copy into the database "if on CD" (1) went with the former import
    /// of CDs and DVDs: it is now the choice the copy asks for (2).
    public static func migrateCopyToDatabaseMode(in store: any PreferenceStore) {
        if store[DatabasePreferences.copyToDatabaseMode] == 1 {
            store.set(2, for: DatabasePreferences.copyToDatabaseMode)
        }
    }

    /// Counts this launch; answers the count before it. The count is
    /// registered as 1, so a first launch answers 1 too.
    public static func countLaunch(in store: any PreferenceStore) -> Int {
        let count = store[ApplicationPreferences.startCount]
        store.set(count + 1, for: ApplicationPreferences.startCount)
        return count
    }

    /// What the viewers start from, written as a switch: the next series opens
    /// in the same viewer when it is of the same study, and the system is
    /// later than Mac OS X 10.6, which former plugins read here.
    public static func applyViewerValues(in store: any PreferenceStore) {
        store.set(true, for: ViewerPreferences.sameStudy.reading(as: Bool.self))
        store.set(true, for: ApplicationPreferences.hasMacOSXSnowLeopard)
    }

    /// The hot keys of the double click (full screen, the 3D synchronization,
    /// the key image), added to a list of an earlier version that has none of
    /// the three. A list with every action already has them.
    public static func addDoubleClickHotKeys(in store: any PreferenceStore) {
        let key = ViewerPreferences.hotKeys.name
        let hotKeys = store.object(forKey: key) as? [String: Any]
        guard (hotKeys?.count ?? 0) < HotKeyAction.setKeyImage else { return }
        let doubleClick = [HotKeyAction.fullScreen, HotKeyAction.sync3D, HotKeyAction.setKeyImage]
        if hotKeys?.values.contains(where: { doubleClick.contains(integer($0)) }) == true { return }
        var updated = hotKeys
        updated?["dbl-click"] = HotKeyAction.fullScreen
        updated?["dbl-click + alt"] = HotKeyAction.sync3D
        updated?["dbl-click + cmd"] = HotKeyAction.setKeyImage
        store.set(updated, forKey: key)
    }

    /// The actions of the double click, as the HotKeyActions enum of the
    /// application numbers them.
    enum HotKeyAction {
        static let fullScreen = 50
        static let sync3D = 51
        static let setKeyImage = 52
    }

    /// A number or its text as `intValue` reads it; 0 for anything else.
    private static func integer32(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return Int(number.int32Value) }
        if let text = value as? String { return Int((text as NSString).intValue) }
        return 0
    }

    /// A number or its text as `integerValue` reads it; 0 for anything else.
    private static func integer(_ value: Any) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return (text as NSString).integerValue }
        return 0
    }
}
