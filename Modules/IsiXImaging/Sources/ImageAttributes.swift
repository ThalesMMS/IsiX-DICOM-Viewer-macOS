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

import CoreGraphics
import Foundation

/// How the stored samples are laid out (group 0028).
public struct PixelDescription: Equatable, Sendable {
    public var isSigned = false
    public var bitsAllocated: Int16 = 0
    public var bitsStored: Int16 = 0
    public var width = 0
    public var height = 0
    public var planarConfiguration = 0
    /// Colour samples, or a palette the parser expands to colour.
    public var isRGB = false

    public init() {}
}

/// The modality LUT as a line: stored value times slope plus intercept, in the
/// unit the rescale type names.
public struct ModalityRescale: Equatable, Sendable {
    public var slope: Float = 0
    public var intercept: Float = 0
    public var rescaleType: String?

    public init() {}
}

/// The window the acquisition chose (Window Center and Width).
public struct StoredWindow: Equatable, Sendable {
    public var level: Float = 0
    public var width: Float = 0

    public init() {}
}

/// What the object says about how and of what it was acquired.
public struct AcquisitionParameters: Equatable, Sendable {
    public var sopClassUID: String?
    public var referencedSOPInstanceUID: String?
    public var imageType: String?
    public var frameOfReferenceUID: String?
    public var repetitionTime: String?
    public var echoTime: String?
    public var flipAngle: String?
    public var viewPosition: String?
    public var patientPosition: String?
    public var laterality: String?
    public var positionerPrimaryAngle: NSNumber?
    public var positionerSecondaryAngle: NSNumber?
    public var cineRate: Float = 0
    /// An ophthalmic frame's place on the image it refers to.
    public var referenceCoordinates: [Float] = [0, 0, 0, 0]

    public init() {}
}

/// The display shutter: a rectangle, a circle or a polygon outside which the
/// image is not shown.
public struct DisplayShutter: Equatable, Sendable {
    public var enabled = false
    public var rect = CGRect.zero
    public var circularCenter = CGPoint.zero
    public var circularRadius = 0
    /// Set when the object stated a polygon, replacing any earlier one.
    public var polygon: [CGPoint]?

    public init() {}
}

/// One region of an ultrasound image and its physical calibration.
public struct UltrasoundRegion: Equatable, Sendable {
    public var regionSpatialFormat: Int32 = 0
    public var regionDataType: Int32 = 0
    public var regionFlags: Int32 = 0
    public var regionLocationMinX0: Int32 = 0
    public var regionLocationMinY0: Int32 = 0
    public var regionLocationMaxX1: Int32 = 0
    public var regionLocationMaxY1: Int32 = 0
    public var referencePixelX0: Int32 = 0
    public var isReferencePixelX0Present = false
    public var referencePixelY0: Int32 = 0
    public var isReferencePixelY0Present = false
    public var physicalUnitsXDirection: Int32 = 0
    public var physicalUnitsYDirection: Int32 = 0
    public var refPixelPhysicalValueX = 0.0
    public var refPixelPhysicalValueY = 0.0
    public var physicalDeltaX = 0.0
    public var physicalDeltaY = 0.0
    public var dopplerCorrectionAngle = 0.0

    public init() {}

    /// The region's values under the names of the app's region object's
    /// properties, so that it can take them by key.
    public var keyedValues: [String: Any] {
        ["regionSpatialFormat": regionSpatialFormat, "regionDataType": regionDataType,
         "regionFlags": regionFlags,
         "regionLocationMinX0": regionLocationMinX0, "regionLocationMinY0": regionLocationMinY0,
         "regionLocationMaxX1": regionLocationMaxX1, "regionLocationMaxY1": regionLocationMaxY1,
         "referencePixelX0": referencePixelX0, "isReferencePixelX0Present": isReferencePixelX0Present,
         "referencePixelY0": referencePixelY0, "isReferencePixelY0Present": isReferencePixelY0Present,
         "physicalUnitsXDirection": physicalUnitsXDirection, "physicalUnitsYDirection": physicalUnitsYDirection,
         "refPixelPhysicalValueX": refPixelPhysicalValueX, "refPixelPhysicalValueY": refPixelPhysicalValueY,
         "physicalDeltaX": physicalDeltaX, "physicalDeltaY": physicalDeltaY,
         "dopplerCorrectionAngle": dopplerCorrectionAngle]
    }
}

/// Everything the attribute reading establishes for one image.
public struct ImageAttributes: Equatable, Sendable {
    public var geometry = ImagePlaneGeometry()
    public var pixels = PixelDescription()
    public var rescale = ModalityRescale()
    public var storedWindow = StoredWindow()
    public var acquisition = AcquisitionParameters()
    public var shutter = DisplayShutter()
    /// Set when the object carries a Sequence of Ultrasound Regions,
    /// replacing the regions read before.
    public var ultrasoundRegions: [UltrasoundRegion]?
    public var overlays = [OverlayPlane](repeating: OverlayPlane(), count: OverlayPlane.maximumCount)
    public var suv = SUVParameters()

    public init() {}
}
