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

/// One viewer of a saved layout of the 2D viewers ("windows state"): what a
/// study keeps of a viewer that showed it, saved as one dictionary of an XML
/// property list in the study (and archived as a DICOM SR), and read back when
/// the study opens again.
///
/// The keys are those of the dictionaries the viewers always wrote, each with
/// the type of value it always held; an optional member is a key that a
/// dictionary may lack. Which entries a study keeps is
/// `ViewerWindowsState.entries(of:patients:patientUID:)`.
public struct ViewerWorkspaceEntry: Codable, Sendable, Equatable {

    /// A preference copied into the entry as it is stored: the tiling menu
    /// stores a number and the tiling a text, and a switch may be stored as a
    /// Boolean or as a number.
    public enum StoredPreference: Codable, Sendable, Equatable {
        case boolean(Bool)
        case integer(Int)
        case real(Double)
        case text(String)

        /// The value of a stored property-list object; nil for anything that
        /// is not a number or a text.
        public init?(_ object: Any) {
            if let number = object as? NSNumber {
                if CFGetTypeID(number) == CFBooleanGetTypeID() {
                    self = .boolean(number.boolValue)
                } else if CFNumberIsFloatType(number) {
                    self = .real(number.doubleValue)
                } else {
                    self = .integer(number.intValue)
                }
            } else if let text = object as? String {
                self = .text(text)
            } else {
                return nil
            }
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let flag = try? container.decode(Bool.self) {
                self = .boolean(flag)
            } else if let number = try? container.decode(Int.self) {
                self = .integer(number)
            } else if let number = try? container.decode(Double.self) {
                self = .real(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .boolean(let flag): try container.encode(flag)
            case .integer(let number): try container.encode(number)
            case .real(let number): try container.encode(number)
            case .text(let text): try container.encode(text)
            }
        }
    }

    /// The name of the layout.
    public var name: String
    /// The window's frame, "x y width height" (`ViewerWindowsState.windowPosition`).
    public var windowPosition: String?
    /// The usable rect of the window's screen, as NSStringFromRect writes it.
    public var screen: String?
    /// The index of the window's screen, NSNotFound without one.
    public var screenIndex: UInt?
    /// The image tiling of the viewer.
    public var rows: Int
    public var columns: Int
    /// The image shown, counted from the first image the user sees.
    public var index: Int32
    /// The window level and width, as stored before any SUV conversion.
    public var windowLevel: Float
    public var windowWidth: Float
    /// The zoom, the pan, the rotation and the flips of the view.
    public var scale: Float
    public var x: Double
    public var y: Double
    public var rotation: Float
    public var xFlipped: Bool
    public var yFlipped: Bool
    public var studyInstanceUID: String
    /// The series of the movie frames (`ViewerWindowsState.seriesInstanceUID(of:)`).
    public var seriesInstanceUID: String?
    /// The DICOM Series Instance UID; a series made from a raster file has none.
    public var seriesDICOMUID: String?
    /// Whether the viewer has more than one movie frame.
    public var is4D: Bool
    /// The windows tiling preference ("LastWindowsTilingRowsColumns").
    public var lastWindowsTilingRowsColumns: StoredPreference?
    /// The settings propagation preference ("COPYSETTINGS").
    public var propagateSettings: StoredPreference
    /// Whether the views were synchronized by location (true) or not at all
    /// (false); absent for the other kinds of synchronization.
    public var syncSettings: Bool?
    public var syncButtonBehaviorIsBetweenStudies: Bool
    public var syncSeries: Bool
    /// The view's offset to the others, kept when the synchronization is
    /// between studies.
    public var syncRelativeDiff: Float?
    public var date: Date

    enum CodingKeys: String, CodingKey {
        case name
        case windowPosition = "window position"
        case screen, screenIndex, rows, columns, index
        case windowLevel = "wl"
        case windowWidth = "ww"
        case scale, x, y, rotation, xFlipped, yFlipped, studyInstanceUID, seriesInstanceUID, seriesDICOMUID
        case is4D = "4DData"
        case lastWindowsTilingRowsColumns = "LastWindowsTilingRowsColumns"
        case propagateSettings, syncSettings
        case syncButtonBehaviorIsBetweenStudies = "SyncButtonBehaviorIsBetweenStudies"
        case syncSeries = "SYNCSERIES"
        case syncRelativeDiff, date
    }

    public init(name: String, windowPosition: String?, screen: String?, screenIndex: UInt?, rows: Int, columns: Int, index: Int32,
                windowLevel: Float, windowWidth: Float, scale: Float, x: Double, y: Double, rotation: Float, xFlipped: Bool, yFlipped: Bool,
                studyInstanceUID: String, seriesInstanceUID: String?, seriesDICOMUID: String?, is4D: Bool,
                lastWindowsTilingRowsColumns: StoredPreference?, propagateSettings: StoredPreference, syncSettings: Bool?,
                syncButtonBehaviorIsBetweenStudies: Bool, syncSeries: Bool, syncRelativeDiff: Float?, date: Date) {
        self.name = name
        self.windowPosition = windowPosition
        self.screen = screen
        self.screenIndex = screenIndex
        self.rows = rows
        self.columns = columns
        self.index = index
        self.windowLevel = windowLevel
        self.windowWidth = windowWidth
        self.scale = scale
        self.x = x
        self.y = y
        self.rotation = rotation
        self.xFlipped = xFlipped
        self.yFlipped = yFlipped
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.seriesDICOMUID = seriesDICOMUID
        self.is4D = is4D
        self.lastWindowsTilingRowsColumns = lastWindowsTilingRowsColumns
        self.propagateSettings = propagateSettings
        self.syncSettings = syncSettings
        self.syncButtonBehaviorIsBetweenStudies = syncButtonBehaviorIsBetweenStudies
        self.syncSeries = syncSeries
        self.syncRelativeDiff = syncRelativeDiff
        self.date = date
    }

    /// The entry without the keys that describe the whole layout
    /// (`ViewerWindowsState.layoutKeys`): what a part of a layout keeps.
    public var withoutLayout: ViewerWorkspaceEntry {
        var part = self
        part.windowPosition = nil
        part.screen = nil
        part.screenIndex = nil
        part.lastWindowsTilingRowsColumns = nil
        return part
    }

    /// The saved layout `entries` as the XML property list the studies keep:
    /// encoded as a property list, then written by PropertyListSerialization,
    /// so that the text (the keys in order, the numbers as they were printed)
    /// is the one the dictionaries gave.
    public static func propertyList(_ entries: [ViewerWorkspaceEntry]) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let object = try PropertyListSerialization.propertyList(from: encoder.encode(entries), format: nil)
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    /// The entries of a saved layout.
    public static func entries(from propertyList: Data) throws -> [ViewerWorkspaceEntry] {
        try PropertyListDecoder().decode([ViewerWorkspaceEntry].self, from: propertyList)
    }
}

extension ViewerWindowsState {

    /// The viewers of a saved layout that a study of `patientUID` keeps.
    ///
    /// `patients[i]` is the patient of `state[i]`, compared as
    /// -databaseOpenStudy: compares them (case, diacritics and width
    /// ignored): the whole layout would put another patient's series, window
    /// and zoom into the study's state. When the patient keeps only part of
    /// the layout, each of its entries loses the keys of the whole layout.
    public static func entries(of state: [ViewerWorkspaceEntry], patients: [String], patientUID: String?) -> [ViewerWorkspaceEntry] {
        var own: [ViewerWorkspaceEntry] = []
        for i in 0..<min(state.count, patients.count)
        where (patients[i] as NSString).compare(patientUID ?? "", options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame {
            own.append(state[i])
        }
        if own.count == state.count { return own }
        return own.map(\.withoutLayout)
    }
}
