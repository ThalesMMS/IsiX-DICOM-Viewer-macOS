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

    /// From the user's defaults, when the application registered its own.
    public init(defaults: UserDefaults) {
        commentsFromDICOMFiles = defaults.bool(forKey: "CommentsFromDICOMFiles")
        commentsAutoFill = defaults.bool(forKey: "COMMENTSAUTOFILL")
        separateCardiac4D = defaults.bool(forKey: "SEPARATECARDIAC4D")
        let int = { (key: String) in Self.intValue(defaults.object(forKey: key)) }
        commentsGroup = int("COMMENTSGROUP")
        commentsElement = int("COMMENTSELEMENT")
        commentsGroup2 = int("COMMENTSGROUP2")
        commentsElement2 = int("COMMENTSELEMENT2")
        commentsGroup3 = int("COMMENTSGROUP3")
        commentsElement3 = int("COMMENTSELEMENT3")
        commentsGroup4 = int("COMMENTSGROUP4")
        commentsElement4 = int("COMMENTSELEMENT4")
        useSeriesDescription = defaults.bool(forKey: "useSeriesDescription")
        splitMultiEchoMR = defaults.bool(forKey: "splitMultiEchoMR")
        noLocalizer = defaults.bool(forKey: "NOLOCALIZER")
        oneFileOnSeriesForUS = defaults.bool(forKey: "oneFileOnSeriesForUS")
        combineProjectionSeries = defaults.bool(forKey: "combineProjectionSeries")
        combineProjectionSeriesMode = defaults.bool(forKey: "combineProjectionSeriesMode") ? 1 : 0
        usePatientBirthDateForUID = defaults.bool(forKey: "UsePatientBirthDateForUID")
        usePatientIDForUID = defaults.bool(forKey: "UsePatientIDForUID")
        usePatientNameForUID = defaults.bool(forKey: "UsePatientNameForUID")
    }

    /// From a dictionary of preferences: the factory settings with the user's
    /// own over them, for a tool that has not registered the application's.
    /// Each value is read with -intValue, and a switch keeps what a BOOL keeps
    /// of it (its low byte).
    public init(dictionary: NSDictionary) {
        let int = { (key: String) in Self.intValue(dictionary.object(forKey: key)) }
        let bool = { (key: String) in Int8(truncatingIfNeeded: int(key)) != 0 }
        commentsFromDICOMFiles = bool("CommentsFromDICOMFiles")
        commentsAutoFill = bool("COMMENTSAUTOFILL")
        separateCardiac4D = bool("SEPARATECARDIAC4D")
        commentsGroup = int("COMMENTSGROUP")
        commentsElement = int("COMMENTSELEMENT")
        commentsGroup2 = int("COMMENTSGROUP2")
        commentsElement2 = int("COMMENTSELEMENT2")
        commentsGroup3 = int("COMMENTSGROUP3")
        commentsElement3 = int("COMMENTSELEMENT3")
        commentsGroup4 = int("COMMENTSGROUP4")
        commentsElement4 = int("COMMENTSELEMENT4")
        useSeriesDescription = bool("useSeriesDescription")
        splitMultiEchoMR = bool("splitMultiEchoMR")
        noLocalizer = bool("NOLOCALIZER")
        combineProjectionSeries = bool("combineProjectionSeries")
        oneFileOnSeriesForUS = bool("oneFileOnSeriesForUS")
        combineProjectionSeriesMode = int("combineProjectionSeriesMode")
        usePatientBirthDateForUID = bool("UsePatientBirthDateForUID")
        usePatientIDForUID = bool("UsePatientIDForUID")
        usePatientNameForUID = bool("UsePatientNameForUID")
    }

    /// -intValue of a number or a string; 0 for anything else.
    static func intValue(_ value: Any?) -> Int32 {
        if let number = value as? NSNumber { return number.int32Value }
        if let string = value as? NSString { return string.intValue }
        return 0
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
