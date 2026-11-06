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

/// What a change of the preferences asks of the application, found by comparing
/// the preferences before it with the preferences after it: the viewers to draw
/// or read again, the database list, its columns, the PET fusion's colour table,
/// the servers that need the application restarted and the series lists.
///
/// Each key is read on both sides as its catalog type reads it, so a value is
/// compared, never a type: a number the defaults registered as text ("0") and
/// the same number a pane or a binding wrote (0) are one value. A typed cast of
/// the text gave nil on one side only, so every check after any write (a window
/// frame, the tiling) saw such a key change and made every viewer re-apply its
/// window to every image, loading on the main thread the images of a series
/// still being loaded or retrieved.
///
/// COPYSETTINGS (propagation between series) is not looked at: no viewer draws
/// it, and the tiling, Sync, fusion and the hanging protocols turn it off and on
/// around their own work. Refreshing the viewers for it gave seconds of
/// beachball after tiling a second window during a retrieve.
public struct PreferenceChange: Sendable, Equatable {
    /// The series lists move between the floating panels and the viewers'
    /// windows (UseFloatingThumbnailsList).
    public var seriesListMode = false
    /// The series lists of the viewers show or hide (SeriesListVisible).
    public var seriesListVisible = false
    /// The viewers draw their images again: the interpolation, the ROIs' labels
    /// and their statistics, the length unit.
    public var viewerRefresh = false
    /// The viewers read their series again: the DICOM overlays.
    public var viewerReload = false
    /// The viewers are only redrawn, their images are not touched: the mark of
    /// a previous study.
    public var viewerRedraw = false
    /// The measurements write their lengths otherwise (unit or decimals).
    public var lengthPresentation = false
    /// The labels' size changed in the Viewers pane, whose field writes the key
    /// without the notification the font size menu posts.
    public var labelFontSize = false
    /// The colour table of the PET fusion changed.
    public var petBlendingCLUT = false
    /// The database list writes its dates, names or order otherwise.
    public var databaseRefresh = false
    /// The database list's columns changed.
    public var databaseColumns = false
    /// The web, XML-RPC or listener settings changed: they apply when the
    /// application starts again.
    public var listenerRestart = false
    /// The text preferences whose previous value was there but was not text,
    /// in the order they are looked at. A key seen for the first time is not
    /// one of them.
    public var mistypedTextKeys: [String] = []

    public init() {}

    /// What changed from `previous` to `current`, two readings of the whole
    /// preferences (`dictionaryRepresentation()`); nil when they are equal,
    /// when there is nothing to answer.
    public init?(from previous: [String: Any], to current: [String: Any]) {
        if Self.isSamePropertyList(previous, current) { return nil }
        let compared = Comparison(previous: previous, current: current)

        seriesListMode = compared.switchChanged(ViewerPreferences.useFloatingThumbnailsList)
        seriesListVisible = compared.integerChanged(ViewerPreferences.seriesListVisible)
        viewerReload = compared.integerChanged(ViewerPreferences.displayDICOMOverlays)
        viewerRefresh = compared.switchChanged(ViewerPreferences.roiPrimaryMeasurementOnly)
            || Self.statisticKeys.contains { compared.switchChanged($0) }
            || compared.integerChanged(ViewerPreferences.roiTextNameOnly)
            || compared.integerChanged(ViewerPreferences.roiTextIfSelected)
            || compared.switchChanged(ViewerPreferences.roiLabelBackground)
            || compared.numberChanged(ViewerPreferences.roiLabelBackgroundOpacity)
            || compared.integerChanged(ViewerPreferences.noInterpolation)
            || compared.integerChanged(ViewerPreferences.softwareInterpolation)
        viewerRedraw = compared.switchChanged(ViewerPreferences.showPreviousExamLabel)
        lengthPresentation = compared.numberChanged(ViewerPreferences.roiLengthUnit)
            || compared.numberChanged(ViewerPreferences.roiLengthDecimals)
        viewerRefresh = viewerRefresh || lengthPresentation
        labelFontSize = compared.numberChanged(ViewerPreferences.labelFONTSIZE)

        var mistyped: [String] = []
        petBlendingCLUT = compared.textChanged(ViewerPreferences.petBlendingCLUT, mistyped: &mistyped)
        let dateFormat = compared.textChanged(DatabasePreferences.databaseDateFormat, mistyped: &mistyped)
        let birthDateFormat = compared.textChanged(DatabasePreferences.databaseBirthDateFormat, mistyped: &mistyped)
        mistypedTextKeys = mistyped

        listenerRestart = Self.listenerKeys.contains { compared.integerChanged($0) }
        databaseRefresh = dateFormat || birthDateFormat
            || compared.integerChanged(DatabasePreferences.hidesPatientName)
            || compared.integerChanged(DatabasePreferences.seriesOrder)
            || compared.integerChanged(DatabasePreferences.keepStudiesOfSamePatientTogether)
        databaseColumns = compared.dictionaryChanged(DatabasePreferences.databaseColumns)
    }

    /// The checks of the statistics the label of a closed ROI shows.
    static let statisticKeys = [ViewerPreferences.roiLabelShowArea, ViewerPreferences.roiLabelShowWH,
                                 ViewerPreferences.roiLabelShowMean, ViewerPreferences.roiLabelShowSDev,
                                 ViewerPreferences.roiLabelShowSum, ViewerPreferences.roiLabelShowMedian,
                                 ViewerPreferences.roiLabelShowMin, ViewerPreferences.roiLabelShowMax]

    /// The servers' settings that apply when the application starts again: the
    /// XML-RPC and web servers (whether they run, their ports, HTTPS), the
    /// listener's check interval and where incoming files go. Who the XML-RPC
    /// server answers is read for every call; HTTPS is set as it starts.
    static var listenerKeys: [PreferenceKey<Int>] {
        [NetworkPreferences.xmlrpcServer.reading(as: Int.self), NetworkPreferences.xmlrpcServerPort,
         NetworkPreferences.xmlrpcServerHTTPS.reading(as: Int.self), NetworkPreferences.webServer.reading(as: Int.self),
         NetworkPreferences.webServerPort, WebPortalPreferences.usesSSL.reading(as: Int.self),
         NetworkPreferences.listenerCheckInterval,
         DatabasePreferences.addsIncomingFilesToDefaultDatabaseOnly.reading(as: Int.self)]
    }

    /// Whether two property lists are equal as Foundation compares them: a
    /// number and a Boolean of the same value are equal, as in the preferences.
    static func isSamePropertyList(_ first: Any?, _ second: Any?) -> Bool {
        guard let first else { return second == nil }
        return (first as AnyObject).isEqual(second)
    }

    /// One key read before and after the change.
    private struct Comparison {
        let previous: [String: Any]
        let current: [String: Any]

        /// A switch, read as `bool(forKey:)` reads it.
        func switchChanged(_ key: PreferenceKey<Bool>) -> Bool {
            Bool.reading(previous[key.name]) != Bool.reading(current[key.name])
        }

        /// A number compared as an integer, as `integer(forKey:)` reads it,
        /// whether the key is a switch or a number.
        func integerChanged<Value>(_ key: PreferenceKey<Value>) -> Bool {
            Int.reading(previous[key.name]) != Int.reading(current[key.name])
        }

        /// A number compared by its value, with its fraction: text is read for
        /// its leading number, as the value a binding shows.
        func numberChanged<Value>(_ key: PreferenceKey<Value>) -> Bool {
            Self.number(previous[key.name]) != Self.number(current[key.name])
        }

        /// A text preference: changed when it was text and is no longer the
        /// same text. A previous value of another type is not compared; the key
        /// is listed in `mistyped`.
        func textChanged(_ key: PreferenceKey<String?>, mistyped: inout [String]) -> Bool {
            guard let before = previous[key.name] else { return false }
            guard let text = before as? String else {
                mistyped.append(key.name)
                return false
            }
            guard let after = Optional<String>.reading(current[key.name]) else { return true }
            return !(text as NSString).isEqual(to: after)
        }

        /// A table: changed unless it was a table and is the same table now.
        func dictionaryChanged<Value>(_ key: PreferenceKey<Value>) -> Bool {
            guard let before = previous[key.name], before is [String: Any] else { return true }
            return !isSamePropertyList(before, current[key.name])
        }

        private static func number(_ value: Any?) -> Double? {
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return (text as NSString).doubleValue }
            return nil
        }
    }
}
