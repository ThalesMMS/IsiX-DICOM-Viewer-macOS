/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation
import IsiXPreferences
import Synchronization

/// The preferences the import of a file reads, taken together once: how the
/// study comments are filled, how series are split or combined, and what the
/// patient's identifier is made of.
public struct ImportSettings: Sendable, Equatable {
    public var commentsFromDICOMFiles = false
    public var commentsAutoFill = false
    public var separateCardiac4D = false
    /// The group and element of the four tags the comments may come from.
    public var commentsGroup: Int32 = 0, commentsElement: Int32 = 0
    public var commentsGroup2: Int32 = 0, commentsElement2: Int32 = 0
    public var commentsGroup3: Int32 = 0, commentsElement3: Int32 = 0
    public var commentsGroup4: Int32 = 0, commentsElement4: Int32 = 0
    public var useSeriesDescription = false
    public var splitMultiEchoMR = false
    public var noLocalizer = false
    public var oneFileOnSeriesForUS = false
    public var combineProjectionSeries = false
    public var combineProjectionSeriesMode: Int32 = 0
    public var usePatientIDForUID = true
    public var usePatientBirthDateForUID = true
    public var usePatientNameForUID = true

    /// Before any is read: what the statics held until then.
    public init() {}

    /// The key whose presence says the application's defaults are registered.
    public static let registeredKey = "TOOLKITPARSER4"

    /// Whether the application's defaults are registered in `preferences`.
    public static func defaultsAreRegistered(in preferences: any PreferenceStore) -> Bool {
        preferences.object(forKey: DatabasePreferences.toolkitParser.name) != nil
    }

    /// From the preferences: the application's, once it registered its
    /// defaults, or, for a tool that has not, the factory settings with the
    /// user's own over them, in memory.
    public init(preferences: any PreferenceStore) {
        typealias Keys = DatabasePreferences
        commentsFromDICOMFiles = preferences[Keys.commentsFromDICOMFiles]
        commentsAutoFill = preferences[Keys.commentsAutoFill]
        separateCardiac4D = preferences[Keys.separateCardiac4D]
        // The preference pane writes each tag as an integer; as before, a
        // number keeps its low 32 bits.
        let tag = { (key: PreferenceKey<Int>) in Int32(truncatingIfNeeded: preferences[key]) }
        commentsGroup = tag(Keys.commentsGroup)
        commentsElement = tag(Keys.commentsElement)
        commentsGroup2 = tag(Keys.commentsGroup2)
        commentsElement2 = tag(Keys.commentsElement2)
        commentsGroup3 = tag(Keys.commentsGroup3)
        commentsElement3 = tag(Keys.commentsElement3)
        commentsGroup4 = tag(Keys.commentsGroup4)
        commentsElement4 = tag(Keys.commentsElement4)
        useSeriesDescription = preferences[Keys.useSeriesDescription]
        splitMultiEchoMR = preferences[Keys.splitMultiEchoMR]
        noLocalizer = preferences[Keys.noLocalizer]
        oneFileOnSeriesForUS = preferences[Keys.oneFileOnSeriesForUS]
        combineProjectionSeries = preferences[Keys.combineProjectionSeries]
        combineProjectionSeriesMode = preferences[Keys.combineProjectionSeriesMode] ? 1 : 0
        usePatientBirthDateForUID = preferences[Keys.usePatientBirthDateForUID]
        usePatientIDForUID = preferences[Keys.usePatientIDForUID]
        usePatientNameForUID = preferences[Keys.usePatientNameForUID]
    }
}

/// The settings every import reads, shared by the threads that import: read
/// once, kept until reset, read again at the next file.
public final class ImportSettingsStore: Sendable {
    private struct State {
        var loaded = false
        var settings = ImportSettings()
    }
    private let state = Mutex(State())

    public init() {}

    /// The settings, as last read (the initial ones before any reading).
    public var settings: ImportSettings {
        state.withLock { $0.settings }
    }

    /// Reads the settings with `read` unless they are read already.
    public func load(_ read: () -> ImportSettings) {
        state.withLock { state in
            guard !state.loaded else { return }
            state.loaded = true
            state.settings = read()
        }
    }

    /// The next `load` reads them again; until then they stay as they are.
    public func reset() {
        state.withLock { $0.loaded = false }
    }
}
