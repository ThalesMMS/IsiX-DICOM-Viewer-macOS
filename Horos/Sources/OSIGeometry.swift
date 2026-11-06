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

import Cocoa

// A slab: a plane and a thickness, centred on the plane. OSIGeometry.h keeps
// the C structure, which the volume ROIs' drawing selector takes; its
// functions and its NSValue support are here, for the app's Swift.

/// A slab of `thickness` on `plane`.
func OSISlabMake(_ plane: N3Plane, _ thickness: CGFloat) -> OSISlab {
    return OSISlab(plane: plane, thickness: thickness)
}

/// The same plane and the same thickness.
func OSISlabEqualTo(_ slab1: OSISlab, _ slab2: OSISlab) -> Bool {
    return N3PlaneEqualToPlane(slab1.plane, slab2.plane) && slab1.thickness == slab2.thickness
}

/// Coincident planes and the same thickness.
func OSISlabIsCoincidentToSlab(_ slab1: OSISlab, _ slab2: OSISlab) -> Bool {
    return N3PlaneIsCoincidentToPlane(slab1.plane, slab2.plane) && slab1.thickness == slab2.thickness
}

/// Whether `vector` is within half the thickness of the plane, with a margin
/// of CGFLOAT_MIN * 1E5 for a slab of no thickness.
func OSISlabContainsVector(_ slab: OSISlab, _ vector: N3Vector) -> Bool {
    return N3VectorDistanceToPlane(vector, slab.plane) - slab.thickness / 2.0 <= (CGFloat.leastNormalMagnitude * 1E5)
}

/// Whether `plane` is parallel to the slab and its point inside it.
func OSISlabContainsPlane(_ slab: OSISlab, _ plane: N3Plane) -> Bool {
    return N3PlaneIsParallelToPlane(slab.plane, plane) && OSISlabContainsVector(slab, plane.point)
}

/// The slab carried by `transform`: its plane, and as thickness the distance
/// from the new plane's point to where the point a thickness away along the
/// normal went.
func OSISlabApplyTransform(_ slab: OSISlab, _ transform: N3AffineTransform) -> OSISlab {
    let topPoint = N3VectorAdd(slab.plane.point, N3VectorScalarMultiply(N3VectorNormalize(slab.plane.normal), slab.thickness))
    let transformedTopPoint = N3VectorApplyTransform(topPoint, transform)

    var transformedSlab = OSISlab()
    transformedSlab.plane = N3PlaneApplyTransform(slab.plane, transform)
    transformedSlab.thickness = N3VectorDistance(transformedSlab.plane.point, transformedTopPoint)
    return transformedSlab
}

/// "{plane, thickness}", the thickness with six decimals.
func NSStringFromOSISlab(_ slab: OSISlab) -> String {
    return String(format: "{%@, %f}", NSStringFromN3Plane(slab.plane) as NSString, Double(slab.thickness))
}

/// The slab as a property list: its plane's dictionary under "plane", its
/// thickness under "thickness".
func OSISlabCreateDictionaryRepresentation(_ slab: OSISlab) -> CFDictionary {
    let planeDict = N3PlaneCreateDictionaryRepresentation(slab.plane).takeRetainedValue()
    let thicknessNumber = NSNumber(value: Double(slab.thickness))
    return ["plane": planeDict, "thickness": thicknessNumber] as NSDictionary
}

/// The slab of a dictionary OSISlabCreateDictionaryRepresentation made, into
/// `slab` when given; false when `dict` is not one.
@discardableResult
func OSISlabMakeWithDictionaryRepresentation(_ dict: CFDictionary?, _ slab: UnsafeMutablePointer<OSISlab>?) -> Bool {
    guard let dict else {
        return false
    }
    let dictionary = dict as NSDictionary
    guard let planeDict = dictionary["plane"] as CFTypeRef?, CFGetTypeID(planeDict) == CFDictionaryGetTypeID(),
          let thicknessNumber = dictionary["thickness"] as CFTypeRef?, CFGetTypeID(thicknessNumber) == CFNumberGetTypeID() else {
        return false
    }
    var tempSlab = OSISlab()
    if N3PlaneMakeWithDictionaryRepresentation((planeDict as! CFDictionary), &tempSlab.plane) == false {
        return false
    }
    // A number that does not fit a CGFloat exactly is still taken, as it was.
    CFNumberGetValue((thicknessNumber as! CFNumber), .cgFloatType, &tempSlab.thickness)
    slab?.pointee = tempSlab
    return true
}

extension NSValue {
    /// @encode(OSISlab), which Swift cannot spell.
    static let osiSlabObjCType = "{OSISlab={N3Plane={N3Vector=ddd}{N3Vector=ddd}}d}"

    /// A value holding `slab`.
    @objc(valueWithOSISlab:)
    public class func value(withOSISlab slab: OSISlab) -> NSValue {
        var slab = slab
        return NSValue(bytes: &slab, objCType: osiSlabObjCType)
    }

    /// The slab a value made by +valueWithOSISlab: holds.
    @objc(OSISlabValue)
    public func osiSlabValue() -> OSISlab {
        var slab = OSISlab()
        assert(String(cString: objCType) == NSValue.osiSlabObjCType)
        getValue(&slab, size: MemoryLayout<OSISlab>.size)
        return slab
    }
}
