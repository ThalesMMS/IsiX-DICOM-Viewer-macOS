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

/// Wrapper for NSPoint.
///
/// The Objective-C name, the selectors and the archived form are those of the
/// former class: ROIs archive their points with NSArchiver and
/// NSKeyedArchiver, and plugins read them.
@objc(MyPoint)
public final class MyPoint: NSObject, NSCoding {
    private static let near = 5.0

    /// The former `pt` ivar, the storage of `point`.
    private var pt = NSPoint.zero

    @objc(point:)
    public class func point(_ a: NSPoint) -> MyPoint {
        return MyPoint(point: a)
    }

    @objc(initWithPoint:)
    public init(point a: NSPoint) {
        pt = a
        super.init()
    }

    /// -init of NSObject, which -copyWithZone: calls: the origin.
    @objc public override init() {
        super.init()
    }

    /// The point is archived unkeyed, as the string NSStringFromPoint gives.
    @objc(initWithCoder:)
    public init?(coder: NSCoder) {
        if let string = coder.decodeObject() as? String {
            pt = NSPointFromString(string)
        }
        super.init()
    }

    @objc(encodeWithCoder:)
    public func encode(with coder: NSCoder) {
        // The NSString Foundation returns, not a Swift string bridged anew.
        coder.encode(NSStringFromPoint(pt) as NSString)
    }

    @objc(copyWithZone:)
    public func copy(with zone: NSZone?) -> Any {
        let p = MyPoint()
        p.pt = pt
        return p
    }

    /// Was atomic. Not any more: the ROI code reads the coordinates through
    /// -x and -y, which never were, and changes points on the main thread.
    @objc public dynamic var point: NSPoint {
        get { return pt }
        set { pt = newValue }
    }

    @objc public var x: Float {
        return Float(pt.x)
    }

    @objc public var y: Float {
        return Float(pt.y)
    }

    @objc(move::)
    public func move(_ x: Float, _ y: Float) {
        pt.x += CGFloat(x)
        pt.y += CGFloat(y)
    }

    @objc(isEqualToPoint:)
    public func isEqual(to a: NSPoint) -> Bool {
        if a.x != pt.x { return false }
        if a.y != pt.y { return false }
        return true
    }

    /// NEAR / scale is a double; scale * ratio is a float product, as it was.
    @objc(isNearToPoint:::)
    public func isNear(to a: NSPoint, _ scale: Float, _ ratio: Float) -> Bool {
        let dx = MyPoint.near / Double(scale)
        let dy = MyPoint.near / Double(scale * ratio)
        if Double(a.x) >= Double(pt.x) - dx && Double(a.x) <= Double(pt.x) + dx
            && Double(a.y) >= Double(pt.y) - dy && Double(a.y) <= Double(pt.y) + dy {
            return true
        }
        return false
    }

    public override var description: String {
        return String(format: "[%f,%f]", Double(pt.x), Double(pt.y))
    }
}
