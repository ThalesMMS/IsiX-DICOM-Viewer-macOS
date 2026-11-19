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

/// One region of the Sequence of Ultrasound Regions (0018,6011), as the image
/// keeps it (UltrasoundRegion is what the reader parsed): where it is
/// in the image and how its pixels map to physical units. The image reader
/// fills it by key, with the names of these properties.
///
/// It is the DCMUSRegion of the Horos and OsiriX plugin SDK, under that name
/// for the runtime: the objects -[DCMPix usRegions] hands a plugin are of the
/// class its binary looks up, and answer the eighteen properties and
/// -toString with the types that SDK declared (int, double, BOOL). The
/// eighteen stored properties are also the instance variables the SDK
/// declared, under the same names and with the same types: the application
/// exports the offset of each under the name a plugin's binary binds when it
/// loads, so that none may change its name, its type, or stop being stored.
/// A plugin's Objective-C subclass of a Swift class has none of its metadata:
/// no known plugin makes one of this class, and one that did would have to
/// be checked.
@objc(DCMUSRegion)
public final class USRegion: NSObject {
    // DICOM TAGS
    @objc public var regionSpatialFormat: Int32 = 0        // (0018,6012) [0000H...0005H]
    @objc public var regionDataType: Int32 = 0             // (0018,6014) [0000H...0012H]
    @objc public var regionFlags: Int32 = 0                // (0018,6016) [0,1]

    @objc public var regionLocationMinX0: Int32 = 0        // (0018,6018)
    @objc public var regionLocationMinY0: Int32 = 0        // (0018,601A)
    @objc public var regionLocationMaxX1: Int32 = 0        // (0018,601C)
    @objc public var regionLocationMaxY1: Int32 = 0        // (0018,601E)

    @objc public var referencePixelX0: Int32 = 0           // (0018,6020) [optional]
    @objc public var referencePixelY0: Int32 = 0           // (0018,6022) [optional]

    @objc public var physicalUnitsXDirection: Int32 = 0    // (0018,6024) [0000H...000CH]
    @objc public var physicalUnitsYDirection: Int32 = 0    // (0018,6026) [0000H...000CH]

    @objc public var refPixelPhysicalValueX: Double = 0    // (0018,6028)
    @objc public var refPixelPhysicalValueY: Double = 0    // (0018,602A)

    @objc public var physicalDeltaX: Double = 0            // (0018,602C)
    @objc public var physicalDeltaY: Double = 0            // (0018,602E) [<0:dir=up, >0:dir=down]

    @objc public var dopplerCorrectionAngle: Double = 0    // (0018,6034)

    // Optional Tags
    @objc public var isReferencePixelX0Present = false
    @objc public var isReferencePixelY0Present = false

    /// Each tag as name=value, in the order above, each followed by a space;
    /// the presence flags are not written.
    @objc public func toString() -> String {
        let integers: [(String, Int32)] = [
            ("regionSpatialFormat", regionSpatialFormat), ("regionDataType", regionDataType), ("regionFlags", regionFlags),
            ("regionLocationMinX0", regionLocationMinX0), ("regionLocationMinY0", regionLocationMinY0),
            ("regionLocationMaxX1", regionLocationMaxX1), ("regionLocationMaxY1", regionLocationMaxY1),
            ("referencePixelX0", referencePixelX0), ("referencePixelY0", referencePixelY0),
            ("physicalUnitsXDirection", physicalUnitsXDirection), ("physicalUnitsYDirection", physicalUnitsYDirection),
        ]
        let reals: [(String, Double)] = [
            ("refPixelPhysicalValueX", refPixelPhysicalValueX), ("refPixelPhysicalValueY", refPixelPhysicalValueY),
            ("physicalDeltaX", physicalDeltaX), ("physicalDeltaY", physicalDeltaY),
            ("dopplerCorrectionAngle", dopplerCorrectionAngle),
        ]
        return integers.map { "\($0.0)=\(NSNumber(value: $0.1).stringValue) " }.joined()
            + reals.map { "\($0.0)=\(NSNumber(value: $0.1).stringValue) " }.joined()
    }
}

// MARK: - Measuring in a region

extension USRegion {
    /// Whether the pixel lies in the region, its edges included.
    public func holds(x: Int32, y: Int32) -> Bool {
        x >= regionLocationMinX0 && x <= regionLocationMaxX1 && y >= regionLocationMinY0 && y <= regionLocationMaxY1
    }

    /// A region to measure in: one with a spatial format or units.
    public var measures: Bool {
        !(regionSpatialFormat == 0 && physicalUnitsXDirection == 0 && physicalUnitsYDirection == 0)
    }

    /// A 2D region in centimetres both ways, where a length is one length.
    public var isTwoDimensionalInCentimetres: Bool {
        regionSpatialFormat == 1 && physicalUnitsXDirection == 3 && physicalUnitsYDirection == 3
    }

    /// The pixel spacing of the region, in mm: its own physical deltas, for a
    /// 2D region in centimetres that gives both. An image may hold several
    /// such regions, each with its scale, and the image's pixel spacing is
    /// that of one of them only.
    public var pixelSpacing: (x: Double, y: Double)? {
        guard isTwoDimensionalInCentimetres, physicalDeltaX != 0, physicalDeltaY != 0 else { return nil }
        return (abs(physicalDeltaX) * 10, abs(physicalDeltaY) * 10)
    }

    /// The region a line from one pixel to another is measured in: the first
    /// of `regions` that holds both ends and measures. nil when no region
    /// holds both, as for a line that crosses from one to another.
    public static func region(holding a: (x: Int32, y: Int32), _ b: (x: Int32, y: Int32), in regions: [USRegion]) -> USRegion? {
        regions.first { $0.measures && $0.holds(x: a.x, y: a.y) && $0.holds(x: b.x, y: b.y) }
    }
}
