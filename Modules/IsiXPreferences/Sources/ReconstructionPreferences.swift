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

/// The preferences of the MPR, the CPR, the orthogonal MPR, the endoscopy and the fly-through. Each key is
/// declared once, with the type it is read as and the value the application registers; `catalog` lists them
/// for DefaultPreferences. A key with nothing registered reads as false, 0 or nil until the user sets it, as
/// the accessor these windows used read it.
public enum ReconstructionPreferences {
    /// The colour of the curved path of the CPR, from 0 to 1: registered by the CPR when it opens (green),
    /// not at launch: `curvedPathColourDefaults`.
    public static let curvedPathColourBlue = PreferenceKey<Float>("CPRColorB")
    public static let curvedPathColourGreen = PreferenceKey<Float>("CPRColorG")
    public static let curvedPathColourRed = PreferenceKey<Float>("CPRColorR")
    /// Whether the CPR exports its three transverse views and the MPR views with the curved one.
    public static let cprExportIncludesAllViews = PreferenceKey<Bool>("exportDCMIncludeAllCPRViews")
    /// CPRInterpolationMode of the CPR's resampling; its absence means the cubic one.
    public static let cprInterpolationMode = PreferenceKey<Int>("selectedCPRInterpolationMode")
    /// Set once the CPR toolbar was given its Stenosis item.
    public static let cprToolbarStenosisInserted = PreferenceKey<Bool>("CPRToolbarStenosisInserted")
    /// Set once the endoscopy toolbar was given its View Angle item.
    public static let endoscopyViewAngleItemShown = PreferenceKey<Bool>("EndoscopyViewAngleToolbarItemShown")
    public static let exportMatrixFor3D = PreferenceKey<Int>("EXPORTMATRIXFOR3D", registered: "0")
    /// Whether the MPR and the orthogonal MPRs export all their views in one image.
    public static let exportIncludesAllViews = PreferenceKey<Bool>("exportDCMIncludeAllViews")
    /// The export of the MPR the user chose last: 0 the series, 1 the current image.
    public static let lastMPRExportMode = PreferenceKey<Int>("lastMPRdcmExportMode")
    public static let logarithmicThickSlabSlider = PreferenceKey<Bool>("LogarithmicThickSlabSlider", registered: false)
    /// The colours of the three axes of the MPR and the CPR, from 0 to 1, saved when the user changes one.
    /// All twelve at 0, as before any change, mean the factory colours.
    public static let mprAxis1Alpha = PreferenceKey<Float>("MPR_AXIS_1_ALPHA")
    public static let mprAxis1Blue = PreferenceKey<Float>("MPR_AXIS_1_BLUE")
    public static let mprAxis1Green = PreferenceKey<Float>("MPR_AXIS_1_GREEN")
    public static let mprAxis1Red = PreferenceKey<Float>("MPR_AXIS_1_RED")
    public static let mprAxis2Alpha = PreferenceKey<Float>("MPR_AXIS_2_ALPHA")
    public static let mprAxis2Blue = PreferenceKey<Float>("MPR_AXIS_2_BLUE")
    public static let mprAxis2Green = PreferenceKey<Float>("MPR_AXIS_2_GREEN")
    public static let mprAxis2Red = PreferenceKey<Float>("MPR_AXIS_2_RED")
    public static let mprAxis3Alpha = PreferenceKey<Float>("MPR_AXIS_3_ALPHA")
    public static let mprAxis3Blue = PreferenceKey<Float>("MPR_AXIS_3_BLUE")
    public static let mprAxis3Green = PreferenceKey<Float>("MPR_AXIS_3_GREEN")
    public static let mprAxis3Red = PreferenceKey<Float>("MPR_AXIS_3_RED")
    /// Whether single MPR planes are drawn with cubic interpolation (Settings → 3D).
    public static let mprCubicDisplay = PreferenceKey<Bool>("HorosMPRCubicDisplay")
    public static let mpr2DViewsPosition = PreferenceKey<Int>("MPR2DViewsPosition", registered: "0")
    /// Whether the MPR and the CPR show the value under the mouse.
    public static let mprDisplaysMousePosition = PreferenceKey<Bool>("MPRDisplayMousePosition")
    public static let opensViewer = PreferenceKey<Bool>("OPENVIEWER", registered: "1")
    /// Whether the endoscopy's wheel moves along the path assistant's path.
    public static let pathAssistantUsesScrollWheel = PreferenceKey<Bool>("PATH_ASSISTANT_USES_SCROLLWHEEL")
    /// Whether the PET-CT exports its three modalities in one image.
    public static let petCTExportsThreeModalities = PreferenceKey<Bool>("export3modalities")
    public static let rememberMPRPlaneAngles = PreferenceKey<Bool>("RememberMPRPlaneAngles", registered: false)
    /// CPRType of the CPR when it closed last.
    public static let savedCPRType = PreferenceKey<Int>("SavedCPRType")
    public static let stackThicknessOrthogonalMPR = PreferenceKey<Int>("stackThicknessOrthoMPR", registered: "20")
    /// Whether the views of the MPR and the CPR zoom together.
    public static let syncsZoomLevelMPR = PreferenceKey<Bool>("syncZoomLevelMPR")
    /// The most states the undo of the MPR, the CPR and the 2D viewer keeps; none at 0 or below.
    public static let undoQueueSize = PreferenceKey<Int>("UndoQueueSize")
    /// The changes of the ROIs are not kept in the undo queue.
    public static let doesNotUseUndoQueueForROIs = PreferenceKey<Bool>("DontUseUndoQueueForROIs")

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        curvedPathColourBlue, curvedPathColourGreen, curvedPathColourRed, cprExportIncludesAllViews,
        cprInterpolationMode, cprToolbarStenosisInserted, endoscopyViewAngleItemShown, exportMatrixFor3D,
        exportIncludesAllViews, lastMPRExportMode, logarithmicThickSlabSlider, mprAxis1Alpha, mprAxis1Blue,
        mprAxis1Green, mprAxis1Red, mprAxis2Alpha, mprAxis2Blue, mprAxis2Green, mprAxis2Red, mprAxis3Alpha,
        mprAxis3Blue, mprAxis3Green, mprAxis3Red, mprCubicDisplay, mpr2DViewsPosition, mprDisplaysMousePosition,
        opensViewer, pathAssistantUsesScrollWheel, petCTExportsThreeModalities,
        rememberMPRPlaneAngles, savedCPRType, stackThicknessOrthogonalMPR, syncsZoomLevelMPR, undoQueueSize,
        doesNotUseUndoQueueForROIs,
    ]
}

// MARK: - What the windows read with the keys

extension ReconstructionPreferences {
    /// The red, green, blue and alpha keys of an axis of the MPR, 1 to 3.
    public static func axisColour(_ axis: Int) -> [PreferenceKey<Float>] {
        switch axis {
        case 1: return [mprAxis1Red, mprAxis1Green, mprAxis1Blue, mprAxis1Alpha]
        case 2: return [mprAxis2Red, mprAxis2Green, mprAxis2Blue, mprAxis2Alpha]
        default: return [mprAxis3Red, mprAxis3Green, mprAxis3Blue, mprAxis3Alpha]
        }
    }

    /// What the CPR registers beneath the user's colour of its curved path when it opens: green.
    public static func curvedPathColourDefaults() -> [String: Any] {
        [curvedPathColourRed.name: NSNumber(value: Float(0)), curvedPathColourGreen.name: NSNumber(value: Float(1)),
         curvedPathColourBlue.name: NSNumber(value: Float(0))]
    }

    /// The key path of `key` in NSUserDefaultsController, whose observers hear a change of the key.
    public static func controllerKeyPath<Value>(_ key: PreferenceKey<Value>) -> String {
        "values." + key.name
    }

    /// The names of a table of presets (window levels, colour tables, opacity tables) in the order of the
    /// menus: as NSString's caseInsensitiveCompare orders them, names equal but for case in the order of
    /// their characters. Every name the table holds is listed, also one whose entry is not of the preset's
    /// form, as the stored dictionary listed them. Empty without a table.
    public static func menuNames<Preset>(_ key: PreferenceKey<[String: Preset]?>, in store: any PreferenceStore) -> [String] {
        menuOrder(Array((store[key.reading(as: [String: PropertyListValue]?.self)] ?? [:]).keys))
    }

    /// `names` in the order of the menus.
    static func menuOrder(_ names: [String]) -> [String] {
        names.sorted { first, second in
            switch first.caseInsensitiveCompare(second) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return first < second
            }
        }
    }

    /// The items of the window levels in the menus of these windows, numbered from 1 in the order of
    /// `menuNames`: "1 - CT - Bone", "12 - Lung". The windows drop the number, of any length, and the
    /// " - " after it to find the preset again.
    public static func windowLevelMenuTitles(in store: any PreferenceStore) -> [String] {
        menuNames(ImagePresetPreferences.windowLevelPresets, in: store).enumerated().map { index, name in "\(index + 1) - \(name)" }
    }

    /// Whether the table `key` has an entry `name`, whatever its form.
    public static func holdsPreset<Preset>(_ name: String?, of key: PreferenceKey<[String: Preset]?>, in store: any PreferenceStore) -> Bool {
        guard let name else { return false }
        return store[key.reading(as: [String: PropertyListValue]?.self)]?[name] != nil
    }

    /// The preset `name` of the table `key`, read alone: nil without one, or when its entry is not of the
    /// preset's form, whatever the other entries hold.
    public static func preset<Preset: PropertyListRepresentable>(_ name: String?, of key: PreferenceKey<[String: Preset]?>,
                                                                 in store: any PreferenceStore) -> Preset? {
        guard let name, let entry = store[key.reading(as: [String: PropertyListValue]?.self)]?[name] else { return nil }
        return Preset(propertyList: entry)
    }

    /// The 256 levels of a channel of a colour table, as the viewers pass them to a view: each value cut to
    /// its lowest byte, 0 where the channel is shorter.
    public static func levels(_ channel: [Int]) -> [UInt8] {
        (0 ..< 256).map { index in index < channel.count ? UInt8(truncatingIfNeeded: channel[index]) : 0 }
    }

    /// The points of an opacity table as they are stored, the text NSStringFromPoint writes, for the views
    /// and the transfer tables that read them in that form; a point that is not text is empty text, which
    /// they read as the origin.
    public static func pointTexts(_ table: OpacityTablePreset) -> [String] {
        (table.propertyList.dictionaryValue?["Points"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
    }
}
