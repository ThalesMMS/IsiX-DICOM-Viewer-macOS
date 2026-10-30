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

// The rules of the region growing window: the four algorithms and their
// parameters, which slice a preview or a computation grows from, what the
// grown ROI is called and whether it merges with the ROIs already there. The
// window and the ITK filters stay in the app.

/// The region growing algorithms, by the tag of their item in the window's
/// popup (the growingRegionAlgorithm preference holds its index).
public enum RegionGrowingAlgorithm: Int, CaseIterable, Sendable {
    /// Connected threshold around the seed's value, ± an interval.
    case interval = 0
    /// Connected threshold between a lower and an upper bound.
    case threshold = 1
    /// Neighborhood connected: lower and upper bounds, and a radius.
    case neighborhood = 2
    /// Confidence connected: a multiplier, a number of iterations and a radius.
    case confidence = 3

    /// The preferences the parameter fields are bound to, one per field, in
    /// the order of the fields.
    public var parameterDefaultsKeys: [String] {
        switch self {
        case .interval: return ["growingRegionInterval"]
        case .threshold: return ["growingRegionLowerThreshold", "growingRegionUpperThreshold"]
        case .neighborhood: return ["growingRegionLowerThreshold", "growingRegionUpperThreshold", "growingRegionRadius"]
        case .confidence: return ["growingRegionMultiplier", "growingRegionIterations", "growingRegionRadius"]
        }
    }

    /// The number of parameter fields.
    public var parameterCount: Int { parameterDefaultsKeys.count }

    /// What each field shows before its preference is bound to it.
    public var defaultValues: [String] {
        switch self {
        case .interval: return ["100"]
        case .threshold: return ["", ""]
        case .neighborhood: return ["", "", "2"]
        case .confidence: return ["2.5", "5", "2"]
        }
    }

    /// The page of the ITK filter's documentation the Help button opens.
    public var helpURL: String {
        switch self {
        case .interval, .threshold:
            return "http://www.itk.org/Doxygen16/html/classitk_1_1ConnectedThresholdImageFilter.html#_details"
        case .neighborhood:
            return "http://www.itk.org/Doxygen16/html/classitk_1_1NeighborhoodConnectedImageFilter.html#_details"
        case .confidence:
            return "http://www.itk.org/Doxygen16/html/classitk_1_1ConfidenceConnectedImageFilter.html#_details"
        }
    }
}

/// The decisions of a preview and of a computation.
public enum RegionGrowingRules {
    /// The interval preference kept to three decimals: multiplied by 1000 in
    /// double precision, cut to a 32-bit integer as a C cast on arm64 cuts it
    /// (toward zero, NaN as 0, saturated), divided by 1000 and rounded to a
    /// float.
    public static func roundedInterval(_ value: Float) -> Float {
        let scaled = Double(value) * 1000
        let truncated: Int32
        if scaled.isNaN {
            truncated = 0
        } else if scaled >= 2_147_483_648 {
            truncated = Int32.max
        } else if scaled <= -2_147_483_649 {
            truncated = Int32.min
        } else {
            truncated = Int32(scaled)
        }
        return Float(Double(truncated) / 1000)
    }

    /// Whether every parameter field has a value: none is the empty string.
    public static func parametersProvided(_ values: [String]) -> Bool {
        values.allSatisfy { !($0 as NSString).isEqual(to: "") }
    }

    /// Whether a preview runs: when previews are on, or when a click grows the
    /// ROI directly.
    public static func previews(previewGrowingRegion: Bool, directlyGenerate: Bool) -> Bool {
        previewGrowingRegion || directlyGenerate
    }

    /// The name of the ROI a preview grows: the preview's name, unless the
    /// preview comes from a click in the viewer, the growing mode is not 3D
    /// (tag 1) and clicks grow the ROI directly, which then takes the name
    /// typed in the window.
    public static func previewROIName(fromViewerClick: Bool, growingModeTag: Int, directlyGenerate: Bool,
                                      typedName: String, previewName: String) -> String {
        if fromViewerClick && growingModeTag != 1 && directlyGenerate { return typedName }
        return previewName
    }

    /// Whether the grown ROI merges with the ROIs already there: never for a
    /// preview (the ROI named `previewName`), else as the preference says.
    public static func mergesExistingROIs(name: String, previewName: String, preference: Bool) -> Bool {
        (name as NSString).isEqual(to: previewName) ? false : preference
    }

    /// The slice a preview grows from: the whole volume (-1) when 3D previews
    /// are on, else the current image.
    public static func previewSlice(preview3D: Bool, currentImage: Int) -> Int {
        preview3D ? -1 : currentImage
    }

    /// The slice a computation grows from: the whole volume (-1) in the 3D
    /// growing mode (tag 1), else the current image.
    public static func computeSlice(growingModeTag: Int, currentImage: Int) -> Int {
        growingModeTag == 1 ? -1 : currentImage
    }

    /// The resolution passed to the filter for the window's slider: its maximum
    /// cut to an integer, plus 1, minus its value; the leftmost position is the
    /// coarsest.
    public static func roiResolution(sliderMaxValue: Double, sliderValue: Int32) -> Int {
        let maximum: Int
        if sliderMaxValue.isNaN {
            maximum = 0
        } else if sliderMaxValue >= 9_223_372_036_854_775_807.0 {
            maximum = Int.max
        } else if sliderMaxValue <= -9_223_372_036_854_775_808.0 {
            maximum = Int.min
        } else {
            maximum = Int(sliderMaxValue)
        }
        return (maximum &+ 1) &- Int(sliderValue)
    }
}
