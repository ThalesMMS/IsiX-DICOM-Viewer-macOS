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

/// Represents a Voxel: x, y and z positions as floats, a value and a size.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIVoxel.h> are those of the former class.
@objc(OSIVoxel)
public final class OSIVoxel: NSObject {
    @objc public var voxelWidth: Float
    @objc public var voxelHeight: Float
    @objc public var voxelDepth: Float
    @objc public var x: Float
    @objc public var y: Float
    @objc public var z: Float
    @NSCopying @objc public var value: NSNumber?
    @objc public var userInfo: Any?

    /** set the x, y, z position */
    @objc(setX:y:z:)
    public func setX(_ x: Float, y: Float, z: Float) {
        self.x = x
        self.y = y
        self.z = z
    }

    @objc public override convenience init() {
        self.init(x: 0, y: 0, z: 0, value: nil)
    }

    // init with x, y, and z
    // As before, the value is retained, not copied.
    @objc(initWithX:y:z:value:)
    public init(x: Float, y: Float, z: Float, value: NSNumber?) {
        self.x = x
        self.y = y
        self.z = z
        self.value = value
        self.voxelWidth = 1.0
        self.voxelHeight = 1.0
        self.voxelDepth = 1.0
        self.userInfo = nil
        super.init()
    }

    // init with the point and the slice
    // As before, the value is not used.
    @objc(initWithPoint:slice:value:)
    public convenience init(point: NSPoint, slice: Int, value: NSNumber?) {
        self.init(x: Float(point.x), y: Float(point.y), z: Float(slice), value: nil)
    }

    @objc(pointWithX:y:z:value:)
    public class func point(withX x: Float, y: Float, z: Float, value: NSNumber?) -> OSIVoxel {
        return OSIVoxel(x: x, y: y, z: z, value: value)
    }

    @objc(pointWithNSPoint:slice:value:)
    public class func point(with point: NSPoint, slice: Int, value: NSNumber?) -> OSIVoxel {
        return OSIVoxel(point: point, slice: slice, value: value)
    }

    @objc(pointWithPoint3D:)
    public class func point(withPoint3D point3D: Point3D?) -> OSIVoxel {
        return OSIVoxel(point3D: point3D)
    }

    @objc(initWithPoint3D:)
    public convenience init(point3D: Point3D?) {
        self.init(x: point3D?.x ?? 0, y: point3D?.y ?? 0, z: point3D?.z ?? 0, value: nil)
    }

    public override var description: String {
        let valueArgument: CVarArg = value ?? ("(null)" as NSString)
        return String(format: "OSIVoxel: x = %2.1f y = %2.1f z = %2.1f value: %@", Double(x), Double(y), Double(z), valueArgument)
    }

    @objc(copyWithZone:)
    public func copy(with zone: NSZone?) -> Any {
        let newPoint = OSIVoxel.point(withX: x, y: y, z: z, value: value)
        newPoint.voxelWidth = voxelWidth
        newPoint.voxelHeight = voxelHeight
        newPoint.voxelDepth = voxelDepth
        newPoint.userInfo = userInfo
        return newPoint
    }

    /** export to xml */
    @objc public func exportToXML() -> NSMutableDictionary {
        let xml = NSMutableDictionary()
        xml.setObject(NSString(format: "%f", Double(self.x)), forKey: "x" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.y)), forKey: "y" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.z)), forKey: "z" as NSString)
        return xml
    }

    /** init with xml dictonary */
    @objc(initWithDictionary:)
    public convenience init(dictionary xml: NSDictionary?) {
        let x1 = (xml?.value(forKey: "x") as AnyObject?)?.floatValue ?? 0
        let y1 = (xml?.value(forKey: "y") as AnyObject?)?.floatValue ?? 0
        let z1 = (xml?.value(forKey: "z") as AnyObject?)?.floatValue ?? 0
        self.init(x: x1, y: y1, z: z1, value: nil)
    }
}
