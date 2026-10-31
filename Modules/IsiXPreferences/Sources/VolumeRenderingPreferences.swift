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

/// The preferences of the volume rendering, the surfaces, the 3D windows, the ROI volume and the
/// segmentation. Each key is declared once, with the type it is read as and the value the application
/// registers; `catalog` lists them for DefaultPreferences.
public enum VolumeRenderingPreferences {
    public static let autorotate3D = PreferenceKey<Bool>("autorotate3D", registered: "1")
    public static let bestRendering = PreferenceKey<Float>("BESTRENDERING", registered: "1.2")
    public static let defaultShading = PreferenceKey<Bool>("defaultShading", registered: true)
    public static let exportOrientationIn3DExport = PreferenceKey<Bool>("exportOrientationIn3DExport", registered: "1")
    public static let growingRegionAlgorithm = PreferenceKey<Int>("growingRegionAlgorithm", registered: 0)
    public static let growingRegionInterval = PreferenceKey<Float>("growingRegionInterval", registered: 100)
    public static let growingRegionIterations = PreferenceKey<Int>("growingRegionIterations", registered: 5)
    public static let growingRegionLowerThreshold = PreferenceKey<Int>("growingRegionLowerThreshold", registered: 0)
    public static let growingRegionMultiplier = PreferenceKey<Float>("growingRegionMultiplier", registered: .float(2.5))
    public static let growingRegionPointCount = PreferenceKey<Int>("growingRegionPointCount", registered: 20)
    public static let growingRegionRadius = PreferenceKey<Int>("growingRegionRadius", registered: 2)
    public static let growingRegionROIName = PreferenceKey<String?>("growingRegionROIName", registered: PreferenceDefault { _ in NSLocalizedString("Growing Region", comment: "") })
    public static let growingRegionROIType = PreferenceKey<Int>("growingRegionROIType", registered: 0)
    public static let growingRegionType = PreferenceKey<Int>("growingRegionType", registered: 0)
    public static let growingRegionUpperThreshold = PreferenceKey<Int>("growingRegionUpperThreshold", registered: 100)
    public static let last3DPreset = PreferenceKey<String?>("LAST_3D_PRESET", registered: "Softw Tissue CT")
    public static let maximum3DTexture = PreferenceKey<Int>("MAX3DTEXTURE", registered: PreferenceDefault { environment in
        // The 3D texture sizes follow the memory the main display's GPU may use.
        let megabytes = environment.graphicsMemory / (1024 * 1024)
        return megabytes >= 256 ? (megabytes >= 512 ? "256" : "128") : (megabytes >= 128 ? "128" : "32")
    })
    public static let maximum3DTextureWithShading = PreferenceKey<Int>("MAX3DTEXTURESHADING", registered: PreferenceDefault { environment in
        let megabytes = environment.graphicsMemory / (1024 * 1024)
        return megabytes >= 512 ? "128" : (megabytes >= 256 ? "64" : "32")
    })
    public static let points3DColorAlpha = PreferenceKey<Float>("points3DcolorAlpha", registered: "1")
    public static let points3DColorBlue = PreferenceKey<Float>("points3DcolorBlue", registered: "0")
    public static let points3DColorGreen = PreferenceKey<Float>("points3DcolorGreen", registered: "0")
    public static let points3DColorRed = PreferenceKey<Float>("points3DcolorRed", registered: "1")
    public static let preview3DGrowingRegion = PreferenceKey<Bool>("preview3DGrowingRegion", registered: true)
    public static let previewGrowingRegion = PreferenceKey<Bool>("previewGrowingRegion", registered: true)
    public static let rescaleDuring3DResampling = PreferenceKey<Bool>("RescaleDuring3DResampling", registered: "1")
    public static let rotate3DAroundPointUnderMouse = PreferenceKey<Bool>("rotate3DAroundPointUnderMouse", registered: "0")
    /// A stored value below this one is raised to it when the defaults are built.
    public static let superSampling = PreferenceKey<Float>("superSampling", registered: "3.5")
    public static let threeDViewerOnAnotherScreen = PreferenceKey<Bool>("ThreeDViewerOnAnotherScreen", registered: "0")
    public static let useDelaunayFor3DRoi = PreferenceKey<Int>("UseDelaunayFor3DRoi", registered: "0")
    public static let vrDefaultViewSize = PreferenceKey<Int>("VRDefaultViewSize", registered: "0")

    // The keys below have no registered value: absent, they read as false, 0 or nil.

    /// The stereo geometry of the VR and surface windows. While a key is absent the window keeps the
    /// value its nib gives the field, so the readers ask whether it is stored before reading it.
    public static let distanceToScreen = PreferenceKey<Double>("DISTANCETOSCREEN")
    public static let eyeSeparation = PreferenceKey<Double>("EYESEPARATION")
    public static let screenHeight = PreferenceKey<Double>("SCREENHEIGHT")
    /// The region growing of the segmentation window: in every frame of a 4D series, merged with the ROIs
    /// of the same name, and grown at the click without a preview.
    public static let growingRegionPropagateIn4D = PreferenceKey<Bool>("growingRegionPropagateIn4D")
    public static let mergeWithExistingROIs = PreferenceKey<Bool>("mergeWithExistingROIs")
    public static let segmentationDirectlyGenerate = PreferenceKey<Bool>("segmentationDirectlyGenerate")
    /// A drag on an NM series sets its window as on a PET one, from the minimum (the PET pane's switch).
    public static let mouseWindowingNM = PreferenceKey<Bool>("mouseWindowingNM")
    /// The radius of a new 3D point; 0 is the view's own default.
    public static let points3DRadius = PreferenceKey<Float>("points3Dradius")
    /// The page settings of the last printing, which a 3D window prints with on one page.
    public static let previousPrintSettings = PreferenceKey<[String: PropertyListValue]?>("previousPrintSettings")
    /// The scissors of the VR cut along a spline through the points rather than along the polygon.
    public static let splineForScissors = PreferenceKey<Bool>("SplineForScissors")
    /// The image a textured surface wears; nil or empty for the application's own texture.
    public static let textureLocation = PreferenceKey<String?>("textureLocation")
    /// A fixed exponent of the Metal renderer's opacity per millimetre; 0 derives it from the rays.
    public static let volumeMetalOpacityExponent = PreferenceKey<Double>("HorosVolumeMetalOpacityExponent")
    /// The memory of the graphics, in megabytes, for which the VR view size was last chosen.
    public static let vramAmount = PreferenceKey<Int>("VRAMAmount")
    /// The bone removal of the VR: the value and the interval it grows from, and the range of the
    /// series, which the sheet's sliders take.
    public static let vrGrowingRegionInterval = PreferenceKey<Float>("VRGrowingRegionInterval")
    public static let vrGrowingRegionMax = PreferenceKey<Float>("VRGrowingRegionMax")
    public static let vrGrowingRegionMin = PreferenceKey<Float>("VRGrowingRegionMin")
    public static let vrGrowingRegionValue = PreferenceKey<Float>("VRGrowingRegionValue")

    /// Every key of this file.
    static let catalog: [any CataloguedPreference] = [
        autorotate3D, bestRendering, defaultShading, exportOrientationIn3DExport, growingRegionAlgorithm,
        growingRegionInterval, growingRegionIterations, growingRegionLowerThreshold, growingRegionMultiplier,
        growingRegionPointCount, growingRegionRadius, growingRegionROIName, growingRegionROIType, growingRegionType,
        growingRegionUpperThreshold, last3DPreset, maximum3DTexture, maximum3DTextureWithShading, points3DColorAlpha,
        points3DColorBlue, points3DColorGreen, points3DColorRed, preview3DGrowingRegion, previewGrowingRegion,
        rescaleDuring3DResampling, rotate3DAroundPointUnderMouse, superSampling, threeDViewerOnAnotherScreen,
        useDelaunayFor3DRoi, vrDefaultViewSize, distanceToScreen, eyeSeparation, screenHeight, growingRegionPropagateIn4D,
        mergeWithExistingROIs, segmentationDirectlyGenerate, mouseWindowingNM, points3DRadius, previousPrintSettings,
        splineForScissors, textureLocation, volumeMetalOpacityExponent, vramAmount, vrGrowingRegionInterval,
        vrGrowingRegionMax, vrGrowingRegionMin, vrGrowingRegionValue,
    ]
}

/// A table of named presets as the preferences keep it (CLUT, OPACITY, WLWW3, Convolution), read and
/// changed entry by entry. Each entry stays as it was stored and is read as `Preset` only when asked: a
/// name keeps its place in the menus, and the other entries are written back untouched, also one that
/// is not of the preset's form, as the dictionaries the 3D windows used to read and write kept them.
public struct PresetTable<Preset: PropertyListRepresentable>: Sendable {
    /// The key of the table.
    public let key: PreferenceKey<[String: Preset]?>
    /// The entries as stored, by name; nil when the key holds no table.
    public private(set) var entries: [String: PropertyListValue]?

    /// The table `key` holds in `store`.
    public init(_ key: PreferenceKey<[String: Preset]?>, in store: any PreferenceStore) {
        self.key = key
        entries = store[key.reading(as: [String: PropertyListValue]?.self)]
    }

    /// Every name of the table, in no order: the menus sort them.
    public var names: [String] {
        entries.map { Array($0.keys) } ?? []
    }

    /// Whether the table has an entry `name`, whatever its form.
    public func contains(_ name: String?) -> Bool {
        guard let name else { return false }
        return entries?[name] != nil
    }

    /// The preset `name`; nil when there is none or the entry is not of the preset's form.
    public subscript(name: String?) -> Preset? {
        guard let name, let entry = entries?[name] else { return nil }
        return Preset(propertyList: entry)
    }

    /// Stores `preset` under `name`, in its own property-list form; nil removes the entry.
    public mutating func set(_ preset: Preset?, named name: String) {
        var changed = entries ?? [:]
        changed[name] = preset?.propertyList
        entries = changed
    }

    /// Writes the table back under its key, every entry in the form it has.
    public func write(to store: any PreferenceStore) {
        store.set(entries.map { $0.mapValues(\.object) }, forKey: key.name)
    }
}

extension PreferenceKey {
    /// The presets of a list (shadingsPresets), each element read as `Element`; an element of another
    /// form is left out rather than emptying the whole list.
    public func elements<Element: PropertyListRepresentable>(in store: any PreferenceStore) -> [Element] where Value == [Element]? {
        (store[reading(as: [PropertyListValue]?.self)] ?? []).compactMap(Element.init(propertyList:))
    }

    /// Whether `store` holds a value of the key, a registered one included.
    public func isStored(in store: any PreferenceStore) -> Bool {
        store.object(forKey: name) != nil
    }
}

extension ColourTablePreset {
    /// The three channels as the views take them, 256 bytes each: each level's integer part kept to its
    /// low eight bits, 0 for a level the table lacks or that is not a number.
    public var bytes: (red: [UInt8], green: [UInt8], blue: [UInt8]) {
        (channelBytes("Red"), channelBytes("Green"), channelBytes("Blue"))
    }

    /// Whether each of the three channels has its 256 levels, every one a number: a table short of
    /// one is not applied where the stored tables were checked so.
    public var hasEveryLevel: Bool {
        ["Red", "Green", "Blue"].allSatisfy { key in
            guard let levels = propertyList.dictionaryValue?[key]?.arrayValue, levels.count >= 256 else { return false }
            return levels.prefix(256).allSatisfy(\.isNumber)
        }
    }

    /// Whether the table has the editor's points, an empty list included: only those open in the editor.
    public var hasEditorPoints: Bool {
        propertyList.dictionaryValue?["Points"] != nil
    }

    private func channelBytes(_ key: String) -> [UInt8] {
        let levels = propertyList.dictionaryValue?[key]?.arrayValue ?? []
        return (0..<256).map { index in
            guard index < levels.count else { return 0 }
            switch levels[index] {
            case .integer(let number): return UInt8(truncatingIfNeeded: number)
            case .real(let number): return UInt8(truncatingIfNeeded: NSNumber(value: number).int64Value)
            case .boolean(let flag): return flag ? 1 : 0
            default: return 0
            }
        }
    }
}

extension OpacityTablePreset {
    /// The table of the opacity editor's points, kept as the editor wrote each one.
    public init(storedPoints: [String]) {
        self.init(propertyList: .dictionary(["Points": .array(storedPoints.map { .string($0) })]))!
    }

    /// The points as stored, each the text NSStringFromPoint wrote, which the views take as they are.
    public var storedPoints: [String] {
        (propertyList.dictionaryValue?["Points"]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
