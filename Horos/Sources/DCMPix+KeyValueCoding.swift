/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, �version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. �See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. �If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: � OsiriX
 �Copyright (c) OsiriX Team
 �All rights reserved.
 �Distributed under GNU - LGPL
 �
 �See http://www.osirix-viewer.com/copyright.html for details.
 � � This software is distributed WITHOUT ANY WARRANTY; without even
 � � the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 � � PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// Key-value coding by the names of the former instance variables. The
/// Objective-C class answered `valueForKey:@"width"` and the other names that
/// have no accessor from its instance variables directly; the state is stored
/// under horos_ names now, and these keys reach it. A key with an accessor is
/// answered by the accessor, as before; C arrays and pointers were never
/// reachable by key.
extension DCMPix {

    private struct Accessor {
        let get: (DCMPix) -> Any?
        let set: (DCMPix, Any?) -> Void
        /// A number or a structure: set to nil, it raised.
        var isScalar = true
    }

    private static func number<T>(_ get: @escaping (DCMPix) -> T, _ set: @escaping (DCMPix, NSNumber) -> Void,
                                  _ box: @escaping (T) -> NSNumber) -> Accessor {
        Accessor(get: { box(get($0)) }, set: { pix, value in
            if let number = value as? NSNumber { set(pix, number) } else if let string = value as? NSString {
                set(pix, NSNumber(value: string.doubleValue))
            }
        })
    }

    private static func object<T: AnyObject>(_ get: @escaping (DCMPix) -> T?, _ set: @escaping (DCMPix, T?) -> Void) -> Accessor {
        Accessor(get: { get($0) }, set: { set($0, $1 as? T) }, isScalar: false)
    }

    nonisolated(unsafe) private static let formerInstanceVariables: [String: Accessor] = [
        "_srcFile": object({ $0.horos_srcFile }, { $0.horos_srcFile = $1 }),
        "URIRepresentationAbsoluteString": object({ $0.horos_URIRepresentationAbsoluteString },
                                                  { $0.horos_URIRepresentationAbsoluteString = $1 }),
        "isBonjour": number({ $0.horos_isBonjour }, { $0.horos_isBonjour = $1.boolValue }, { NSNumber(value: $0) }),
        "fileTypeHasPrefixDICOM": number({ $0.horos_fileTypeHasPrefixDICOM }, { $0.horos_fileTypeHasPrefixDICOM = $1.boolValue },
                                         { NSNumber(value: $0) }),
        "numberOfFrames": number({ $0.horos_numberOfFrames }, { $0.horos_numberOfFrames = $1.int32Value }, { NSNumber(value: $0) }),
        "fIsSigned": number({ $0.horos_fIsSigned }, { $0.horos_fIsSigned = $1.boolValue }, { NSNumber(value: $0) }),
        "bitsAllocated": number({ $0.horos_bitsAllocated }, { $0.horos_bitsAllocated = $1.int16Value }, { NSNumber(value: $0) }),
        "bitsStored": number({ $0.horos_bitsStored }, { $0.horos_bitsStored = $1.int16Value }, { NSNumber(value: $0) }),
        "height": number({ $0.horos_height }, { $0.horos_height = $1.intValue }, { NSNumber(value: $0) }),
        "width": number({ $0.horos_width }, { $0.horos_width = $1.intValue }, { NSNumber(value: $0) }),
        "fPlanarConf": number({ $0.horos_fPlanarConf }, { $0.horos_fPlanarConf = $1.intValue }, { NSNumber(value: $0) }),
        "estimatedRadiographicMagnificationFactor": number({ $0.horos_estimatedRadiographicMagnificationFactor },
                                                           { $0.horos_estimatedRadiographicMagnificationFactor = $1.doubleValue },
                                                           { NSNumber(value: $0) }),
        "pixelSpacingFromUltrasoundRegions": number({ $0.horos_pixelSpacingFromUltrasoundRegions },
                                                    { $0.horos_pixelSpacingFromUltrasoundRegions = $1.boolValue }, { NSNumber(value: $0) }),
        "inverseVal": number({ $0.horos_inverseVal }, { $0.horos_inverseVal = $1.boolValue }, { NSNumber(value: $0) }),
        "subMinMax": Accessor(get: { NSValue(point: $0.horos_subMinMax) }, set: { pix, value in
            if let value = value as? NSValue { pix.horos_subMinMax = value.pointValue }
        }),
        "subtractedfPercent": number({ $0.horos_subtractedfPercent }, { $0.horos_subtractedfPercent = $1.floatValue }, { NSNumber(value: $0) }),
        "subtractedfZ": number({ $0.horos_subtractedfZ }, { $0.horos_subtractedfZ = $1.floatValue }, { NSNumber(value: $0) }),
        "subtractedfZero": number({ $0.horos_subtractedfZero }, { $0.horos_subtractedfZero = $1.floatValue }, { NSNumber(value: $0) }),
        "subtractedfGamma": number({ $0.horos_subtractedfGamma }, { $0.horos_subtractedfGamma = $1.floatValue }, { NSNumber(value: $0) }),
        "maskID": number({ $0.horos_maskID }, { $0.horos_maskID = $1.intValue }, { NSNumber(value: $0) }),
        "maskTime": number({ $0.horos_maskTime }, { $0.horos_maskTime = $1.floatValue }, { NSNumber(value: $0) }),
        "fImageTime": number({ $0.horos_fImageTime }, { $0.horos_fImageTime = $1.floatValue }, { NSNumber(value: $0) }),
        "positionerPrimaryAngle": object({ $0.horos_positionerPrimaryAngle }, { $0.horos_positionerPrimaryAngle = $1 }),
        "positionerSecondaryAngle": object({ $0.horos_positionerSecondaryAngle }, { $0.horos_positionerSecondaryAngle = $1 }),
        "shutterCircular": Accessor(get: { NSValue(point: $0.horos_shutterCircular) }, set: { pix, value in
            if let value = value as? NSValue { pix.horos_shutterCircular = value.pointValue }
        }),
        "shutterCircular_radius": number({ $0.horos_shutterCircular_radius }, { $0.horos_shutterCircular_radius = $1.intValue },
                                         { NSNumber(value: $0) }),
        "shutterPolygonalSize": number({ $0.horos_shutterPolygonalSize }, { $0.horos_shutterPolygonalSize = $1.intValue },
                                       { NSNumber(value: $0) }),
        "imID": number({ $0.horos_imID }, { $0.horos_imID = $1.intValue }, { NSNumber(value: $0) }),
        "imTot": number({ $0.horos_imTot }, { $0.horos_imTot = $1.intValue }, { NSNumber(value: $0) }),
        "convolution": number({ $0.horos_convolution }, { $0.horos_convolution = $1.boolValue }, { NSNumber(value: $0) }),
        "updateToBeApplied": number({ $0.horos_updateToBeApplied }, { $0.horos_updateToBeApplied = $1.boolValue }, { NSNumber(value: $0) }),
        "kernelsize": number({ $0.horos_kernelsize }, { $0.horos_kernelsize = $1.int16Value }, { NSNumber(value: $0) }),
        "normalization": number({ $0.horos_normalization }, { $0.horos_normalization = $1.floatValue }, { NSNumber(value: $0) }),
        "cineRate": number({ $0.horos_cineRate }, { $0.horos_cineRate = $1.floatValue }, { NSNumber(value: $0) }),
        "stack": number({ $0.horos_stack }, { $0.horos_stack = $1.int16Value }, { NSNumber(value: $0) }),
        "stackMode": number({ $0.horos_stackMode }, { $0.horos_stackMode = $1.int16Value }, { NSNumber(value: $0) }),
        "thickSlabVRActivated": number({ $0.horos_thickSlabVRActivated }, { $0.horos_thickSlabVRActivated = $1.boolValue },
                                       { NSNumber(value: $0) }),
        "fixed8bitsWLWW": number({ $0.horos_fixed8bitsWLWW }, { $0.horos_fixed8bitsWLWW = $1.boolValue }, { NSNumber(value: $0) }),
        "ww": number({ $0.horos_ww }, { $0.horos_ww = $1.floatValue }, { NSNumber(value: $0) }),
        "wl": number({ $0.horos_wl }, { $0.horos_wl = $1.floatValue }, { NSNumber(value: $0) }),
        "fullww": number({ $0.horos_fullww }, { $0.horos_fullww = $1.floatValue }, { NSNumber(value: $0) }),
        "fullwl": number({ $0.horos_fullwl }, { $0.horos_fullwl = $1.floatValue }, { NSNumber(value: $0) }),
        "originX": number({ $0.horos_originX }, { $0.horos_originX = $1.doubleValue }, { NSNumber(value: $0) }),
        "originY": number({ $0.horos_originY }, { $0.horos_originY = $1.doubleValue }, { NSNumber(value: $0) }),
        "originZ": number({ $0.horos_originZ }, { $0.horos_originZ = $1.doubleValue }, { NSNumber(value: $0) }),
        "isOriginDefined": number({ $0.horos_isOriginDefined }, { $0.horos_isOriginDefined = $1.boolValue }, { NSNumber(value: $0) }),
        "spacingBetweenSlices": number({ $0.horos_spacingBetweenSlices }, { $0.horos_spacingBetweenSlices = $1.doubleValue },
                                       { NSNumber(value: $0) }),
        "serieNo": number({ $0.horos_serieNo }, { $0.horos_serieNo = $1.intValue }, { NSNumber(value: $0) }),
        "generated": number({ $0.horos_generated }, { $0.horos_generated = $1.boolValue }, { NSNumber(value: $0) }),
        "notAbleToLoadImage": number({ $0.horos_notAbleToLoadImage }, { $0.horos_notAbleToLoadImage = $1.boolValue },
                                     { NSNumber(value: $0) }),
        "VOILUTApplied": number({ $0.horos_VOILUTApplied }, { $0.horos_VOILUTApplied = $1.boolValue }, { NSNumber(value: $0) }),
        "VOILUT_first": number({ $0.horos_VOILUT_first }, { $0.horos_VOILUT_first = $1.int32Value }, { NSNumber(value: $0) }),
        "VOILUT_number": number({ $0.horos_VOILUT_number }, { $0.horos_VOILUT_number = $1.uint32Value }, { NSNumber(value: $0) }),
        "VOILUT_depth": number({ $0.horos_VOILUT_depth }, { $0.horos_VOILUT_depth = $1.uint32Value }, { NSNumber(value: $0) }),
        "blackIndex": number({ $0.horos_blackIndex }, { $0.horos_blackIndex = $1.int8Value }, { NSNumber(value: $0) }),
        "hasSUV": number({ $0.horos_hasSUV }, { $0.horos_hasSUV = $1.boolValue }, { NSNumber(value: $0) }),
        "philipsFactor": number({ $0.horos_philipsFactor }, { $0.horos_philipsFactor = $1.floatValue }, { NSNumber(value: $0) }),
        "flipAngle": object({ $0.horos_flipAngle }, { $0.horos_flipAngle = $1 }),
        "laterality": object({ $0.horos_laterality }, { $0.horos_laterality = $1 }),
        "viewPosition": object({ $0.horos_viewPosition }, { $0.horos_viewPosition = $1 }),
        "patientPosition": object({ $0.horos_patientPosition }, { $0.horos_patientPosition = $1 }),
        "checking": object({ $0.horos_checking }, { $0.horos_checking = $1 }),
        "waveform": object({ $0.horos_waveform }, { $0.horos_waveform = $1 }),
        "usRegions": object({ $0.horos_usRegions }, { $0.horos_usRegions = $1 }),
        "pixArray": object({ $0.horos_pixArray }, { $0.horos_pixArray = $1 }),
        // As an object, not as its class: the probes link this class without the controller.
        "thickSlab": Accessor(get: { $0.horos_thickSlab as AnyObject? }, set: { pix, value in
            _ = pix.perform(NSSelectorFromString("setThickSlabController:"), with: value)
        }, isScalar: false),
        "clutEntryR": number({ $0.horos_clut.entries.r }, { $0.horos_clut.entries.r = $1.uint16Value }, { NSNumber(value: $0) }),
        "clutEntryG": number({ $0.horos_clut.entries.g }, { $0.horos_clut.entries.g = $1.uint16Value }, { NSNumber(value: $0) }),
        "clutEntryB": number({ $0.horos_clut.entries.b }, { $0.horos_clut.entries.b = $1.uint16Value }, { NSNumber(value: $0) }),
        "clutDepthR": number({ $0.horos_clut.depths.r }, { $0.horos_clut.depths.r = $1.uint16Value }, { NSNumber(value: $0) }),
        "clutDepthG": number({ $0.horos_clut.depths.g }, { $0.horos_clut.depths.g = $1.uint16Value }, { NSNumber(value: $0) }),
        "clutDepthB": number({ $0.horos_clut.depths.b }, { $0.horos_clut.depths.b = $1.uint16Value }, { NSNumber(value: $0) }),
        "fSetClut": number({ $0.horos_clut.set }, { $0.horos_clut.set = $1.boolValue }, { NSNumber(value: $0) }),
        "fSetClut16": number({ $0.horos_clut.set16 }, { $0.horos_clut.set16 = $1.boolValue }, { NSNumber(value: $0) }),
        "savedHeightInDB": number({ $0.horos_savedHeightInDB }, { $0.horos_savedHeightInDB = $1.int32Value }, { NSNumber(value: $0) }),
        "savedWidthInDB": number({ $0.horos_savedWidthInDB }, { $0.horos_savedWidthInDB = $1.int32Value }, { NSNumber(value: $0) }),
        "retainedCacheGroup": object({ $0.horos_retainedCacheGroup }, { $0.horos_retainedCacheGroup = $1 }),
        "cachedFileKey": object({ $0.horos_cachedFileKey }, { $0.horos_cachedFileKey = $1 }),
        "loadedFileRevision": object({ $0.horos_loadedFileRevision }, { $0.horos_loadedFileRevision = $1 }),
    ]

    override public func value(forUndefinedKey key: String) -> Any? {
        if let accessor = DCMPix.formerInstanceVariables[key] { return accessor.get(self) }
        return super.value(forUndefinedKey: key)
    }

    override public func setValue(_ value: Any?, forUndefinedKey key: String) {
        guard let accessor = DCMPix.formerInstanceVariables[key] else {
            super.setValue(value, forUndefinedKey: key)
            return
        }
        if value == nil && accessor.isScalar {
            setNilValueForKey(key)
            return
        }
        accessor.set(self, value)
    }
}
