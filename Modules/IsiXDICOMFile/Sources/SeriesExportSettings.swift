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
import IsiXImaging
import IsiXPreferences

/// The options of a DICOM series a 2D viewer exports (DICOMExport): what is
/// captured for each format of the export sheet, the colour bars and
/// annotations the capture keeps, the tiles it takes, the number the series is
/// given and the format choices of the sheet as it opens. The preferences are
/// read once, through the typed keys, when the export begins.
public struct SeriesExportSettings: Sendable, Equatable {

    /// The formats of the DICOM export sheet's Format matrix, by tag, which
    /// -exportDICOMFileInt: takes as its `screenCapture`.
    public enum Format: Int32, Sendable {
        /// The image in memory, 16 bits, the modality kept.
        case memory = 0
        /// What the view shows, 8-bit RGB.
        case screenCapture = 1
        /// What the view shows, in 16 bits, the modality kept.
        case screenCapture16Bit = 2
    }

    /// The numbers a new series is given, before the minute and the second of
    /// the time it begins are added.
    public enum SeriesBase: Int, Sendable {
        /// An export of the DICOM sheet, and a series renamed by its export.
        case sheet = 8200
        /// The images of a series exported one by one.
        case series = 5300
    }

    /// Whether a secondary capture keeps the colour bars the user shows,
    /// rather than hiding them. The Viewer pane binds it; the catalog of
    /// IsiXPreferences does not declare it.
    public static let keepsCLUTBarsForSecondaryCapture = PreferenceKey<Bool>("keepCLUTBarsForSecondaryCapture")

    /// The annotations the user shows (ANNOTATIONS), put back after a capture.
    public var annotations: Int
    /// The colour bars the user shows (CLUTBARS), put back after a capture.
    public var clutBars: Int
    /// Whether a capture keeps the colour bars the user shows.
    public var keepsCLUTBars: Bool
    /// In a viewer showing several images at once, all the tiles side by side.
    public var includesAllTiledViews: Bool

    public init(annotations: Int, clutBars: Int, keepsCLUTBars: Bool, includesAllTiledViews: Bool) {
        self.annotations = annotations
        self.clutBars = clutBars
        self.keepsCLUTBars = keepsCLUTBars
        self.includesAllTiledViews = includesAllTiledViews
    }

    /// From the preferences, as the export reads them when it begins.
    public init(preferences: any PreferenceStore) {
        self.init(annotations: preferences[ViewerPreferences.annotations],
                  clutBars: preferences[ViewerPreferences.clutBars],
                  keepsCLUTBars: preferences[Self.keepsCLUTBarsForSecondaryCapture],
                  includesAllTiledViews: preferences[ViewerPreferences.includeAllTiledViews])
    }

    // MARK: - The capture

    /// Whether the export draws the view for the file, with the colour bars
    /// and annotations of a capture: a screen capture, or every viewer.
    public static func drawsForCapture(format: Int32, allViewers: Bool) -> Bool {
        format != Format.memory.rawValue || allViewers
    }

    /// The colour bars drawn while the export captures: the user's when the
    /// preferences keep them, `hidden` otherwise.
    public func captureCLUTBars(hidden: Int) -> Int {
        ViewCaptureRequest.secondaryCaptureBars(keepsCLUTBars: keepsCLUTBars, current: clutBars, hidden: hidden)
    }

    /// Whether the file keeps the modality of its source: the image in memory
    /// and the 16-bit capture do; the RGB capture is a secondary capture.
    public static func keepsModality(format: Int32) -> Bool {
        switch Format(rawValue: format) {
        case .memory, .screenCapture16Bit: return true
        case .screenCapture, nil: return false
        }
    }

    /// What the view is asked for the file of `format`: without the graphics,
    /// with square pixels, the tiles as the preferences say; 8-bit RGB except
    /// for the image in memory and the 16-bit capture; cropped as the
    /// preferences say unless every viewer is taken.
    public func captureRequest(format: Int32, allViewers: Bool) -> ViewCaptureRequest {
        ViewCaptureRequest(screenCapture: format != Format.memory.rawValue,
                           force8bits: !Self.keepsModality(format: format),
                           removeGraphical: true, squarePixels: true,
                           allTiles: includesAllTiledViews, allowSmartCropping: !allViewers)
    }

    // MARK: - The series

    /// The number of a series that begins at `minute`:`second`.
    public static func seriesNumber(_ base: SeriesBase, minute: Int, second: Int) -> Int {
        base.rawValue + minute + second
    }

    /// The default window of the file, from the view's: C's conversion of a
    /// float to long on arm64, saturated, NaN to 0.
    public static func windowValue(_ x: Float) -> Int {
        if x.isNaN { return 0 }
        if x >= 9223372036854775807.0 { return Int.max }
        if x <= -9223372036854775808.0 { return Int.min }
        return Int(x)
    }

    // MARK: - The sheet

    /// The Format matrix of the sheet as it opens.
    public struct SheetFormat: Sendable, Equatable {
        /// The tag selected.
        public var selected: Int32
        /// Whether the image in memory may be chosen; nil leaves the cell as it was.
        public var memoryEnabled: Bool?
        /// Whether the 16-bit capture may be chosen.
        public var sixteenBitEnabled: Bool

        public init(selected: Int32, memoryEnabled: Bool?, sixteenBitEnabled: Bool) {
            self.selected = selected
            self.memoryEnabled = memoryEnabled
            self.sixteenBitEnabled = sixteenBitEnabled
        }
    }

    /// The format choices of the sheet opened on an image, from the tag
    /// `selected` before: a colour image or a subtraction has no 16-bit
    /// capture, a subtraction no image in memory; a grey image with ROIs is
    /// captured, without them it is exported in 16 bits rather than in RGB;
    /// a fusion is always captured.
    public static func sheetFormat(selected: Int32, isRGB: Bool, subtraction: Bool, hasROIs: Bool,
                                   blending: Bool) -> SheetFormat {
        var format = SheetFormat(selected: selected, memoryEnabled: nil, sixteenBitEnabled: true)
        if isRGB || subtraction {
            if format.selected == Format.screenCapture16Bit.rawValue { format.selected = Format.screenCapture.rawValue }
            format.sixteenBitEnabled = false
            if subtraction {
                if format.selected == Format.memory.rawValue { format.selected = Format.screenCapture.rawValue }
                format.memoryEnabled = false
            }
        } else {
            format.memoryEnabled = true
            if hasROIs {
                format.selected = Format.screenCapture.rawValue
            } else if format.selected == Format.screenCapture.rawValue {
                format.selected = Format.screenCapture16Bit.rawValue
            }
        }
        if blending { format.selected = Format.screenCapture.rawValue }
        return format
    }
}
