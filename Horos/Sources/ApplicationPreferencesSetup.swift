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

import Cocoa
import IsiXPreferences

/// The preferences as the application starts with them: the factory settings
/// registered beneath the user's own, the offer to reset them all, and the
/// steps of IsiXPreferences' LaunchPreferenceMigrations that each launch
/// takes, in the order the launch takes them. The application controller
/// calls each step where it always ran: the registration from `+initialize`,
/// before anything reads a preference, the presets after the plugins load,
/// the rest as the launch finishes.
@MainActor
enum ApplicationPreferencesSetup {
    private static var preferences: UserDefaults { PreferencesSource.process.preferences }

    /// AppKit's constraint visualiser draws a purple window of its own over
    /// ours. Turning it on by writing the preference left it on in the
    /// person's own preference file whenever a run ended any way but its own
    /// quit - for every later run, of any build - and AppKit lists every
    /// domain carrying the key when asked why that window is there. A window
    /// nobody recognises is reported as ours, so the log says when this is
    /// what it is.
    static func adoptLayoutDebugging() {
        #if !DEBUG
        LayoutDebuggingDefaults.adoptForThisProcessOnly(false)
        #else
        LayoutDebuggingDefaults.adoptForThisProcessOnly(true)
        #endif
        if let layoutDebugging = LayoutDebuggingDefaults.reportForCurrentProcess() {
            NSLog("%@", layoutDebugging as NSString)
        }
    }

    /// Registers the factory settings, offers to reset every preference when
    /// the launch holds Command and Option, and brings the preferences of
    /// earlier versions up to date, before the database is chosen.
    static func register() {
        preferences.register(defaults: (DefaultPreferences.applicationDefaults() as? [String: Any]) ?? [:])

        if (BrowserController._currentModifierFlags() & UInt32(NSEvent.ModifierFlags.command.rawValue)) != 0 &&
           (BrowserController._currentModifierFlags() & UInt32(NSEvent.ModifierFlags.option.rawValue)) != 0 {
            let result = HorosAlertPanel.runInformational(title: NSLocalizedString("Reset Preferences", comment: ""), message: NSLocalizedString("Are you sure you want to reset ALL preferences of IsiX DICOM Viewer? All the preferences will be reseted to their default values.", comment: ""), defaultButton: NSLocalizedString("Cancel", comment: ""), alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)

            if result == HorosAlertPanel.alternateResponse {
                for key in preferences.dictionaryRepresentation().keys {
                    preferences.removeObject(forKey: key)
                }
                preferences.synchronize()
            }
        }

        LaunchPreferenceMigrations.applyFixedValues(in: preferences)
        LaunchPreferenceMigrations.migrateAutoClean(in: preferences)

        // DICOMweb nodes of the pilot, stored in SERVERS with retrieveMode 3, move to
        // DICOMWEB_SERVERS before anything reads SERVERS as a list of DIMSE nodes.
        DICOMwebNode.migrateLegacyServers()
        // A WADO password kept in SERVERS in plain text moves to the Keychain.
        WADOCredentials.migrateServers()

        SandboxFileAccess.restore()
        DistributionChannel.configurePreferences()
        #if MACAPPSTORE
        let alternateDatabaseDefault = DatabaseLocation.baseDirectory(forPath: FileManager.default.userApplicationSupportFolderForApp())
        #else
        let alternateDatabaseDefault: String? = nil
        #endif
        DatabaseFirstUse.prepare(alternateDefault: alternateDatabaseDefault, currentDatabaseVersion: CurrentDatabaseVersion)

        LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences)
        #if MACAPPSTORE
        let defaultDatabasePath = NSLocalizedString("(Application storage)", comment: "")
        #else
        let defaultDatabasePath = NSLocalizedString("(Current User Documents folder)", comment: "")
        #endif
        LaunchPreferenceMigrations.applySessionValues(in: preferences, defaultDatabasePath: defaultDatabasePath)
    }

    /// The database chosen at first use is the one opened.
    static func useDefaultDatabaseLocation() {
        LaunchPreferenceMigrations.copyDefaultDatabaseLocation(in: preferences)
    }

    /// The presets of the virtual endoscopy, once the plugins are loaded.
    static func addPresets() {
        LaunchPreferenceMigrations.addEndoscopyPresets(in: preferences)
    }

    /// As the launch finishes: the remembered sources in temporary places are
    /// forgotten, the time zone of the first launch is kept, and the copy
    /// "if on CD" becomes the copy that asks.
    static func migrateAtLaunch() {
        // One rule, in SourceLocation, says where the system empties folders on
        // its own: macOS puts the per-user temporary directory under
        // /private/var/folders/.../T/, which is where a CD's database is copied
        // and opened from.
        for dropped in LaunchPreferenceMigrations.forgetTemporarySources(in: preferences, isTemporary: { SourceLocation.isTemporaryLocation($0) }) {
            NSLog("---- sources: forgetting %@; it is in a temporary location, not a database to come back to", dropped as NSString)
        }
        LaunchPreferenceMigrations.recordTimeZone(in: preferences, secondsFromGMT: NSTimeZone.local.secondsFromGMT())
        LaunchPreferenceMigrations.migrateCopyToDatabaseMode(in: preferences)
    }

    /// Counts this launch; answers the count before it.
    static func countLaunch() -> Int {
        LaunchPreferenceMigrations.countLaunch(in: preferences)
    }

    /// What the viewers start from, and the hot keys of the double click.
    static func applyViewerValues() {
        LaunchPreferenceMigrations.applyViewerValues(in: preferences)
        LaunchPreferenceMigrations.addDoubleClickHotKeys(in: preferences)
    }
}
