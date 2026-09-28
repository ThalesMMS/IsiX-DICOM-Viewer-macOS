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

/// Represents a 3D point, with x, y and z positions as float.
///
/// The Objective-C name and selectors are those of the former class; the
/// properties stay KVO compliant.
@objc(Point3D)
public final class Point3D: NSObject, NSCopying {
    /// The former ivars. The methods that wrote them directly still do, so
    /// they notify key-value observers exactly when the setters are used.
    private var _x: Float
    private var _y: Float
    private var _z: Float

    @objc public dynamic var x: Float {
        get { return _x }
        set { _x = newValue }
    }

    @objc public dynamic var y: Float {
        get { return _y }
        set { _y = newValue }
    }

    @objc public dynamic var z: Float {
        get { return _z }
        set { _z = newValue }
    }

    @objc public class func point() -> Point3D {
        return Point3D()
    }

    @objc(pointWithX:y:z:)
    public class func point(withX x1: Float, y y1: Float, z z1: Float) -> Point3D {
        return Point3D(x: x1, y: y1, z: z1)
    }

    /// Initialized to the origin.
    @objc public override convenience init() {
        self.init(x: 0.0, y: 0.0, z: 0.0)
    }

    @objc(initWithValues:::)
    public convenience init(values x: Float, _ y: Float, _ z: Float) {
        self.init(x: x, y: y, z: z)
    }

    /// A nil point gives the origin, as the messages to nil did.
    @objc(initWithPoint3D:)
    public convenience init(point3D p: Point3D!) {
        self.init(x: p?.x ?? 0, y: p?.y ?? 0, z: p?.z ?? 0)
    }

    @objc(initWithX:y:z:)
    public init(x x1: Float, y y1: Float, z z1: Float) {
        _x = x1
        _y = y1
        _z = z1
        super.init()
    }

    /// Always a Point3D.
    @objc(copyWithZone:)
    public func copy(with zone: NSZone?) -> Any {
        return Point3D(point3D: self)
    }

    @objc(setPoint3D:)
    public func setPoint3D(_ p: Point3D!) {
        _x = p?.x ?? 0
        _y = p?.y ?? 0
        _z = p?.z ?? 0
    }

    @objc(add:)
    public func add(_ p: Point3D!) {
        _x = _x + (p?.x ?? 0)
        _y = _y + (p?.y ?? 0)
        _z = _z + (p?.z ?? 0)
    }

    @objc(subtract:)
    public func subtract(_ p: Point3D!) {
        _x = _x - (p?.x ?? 0)
        _y = _y - (p?.y ?? 0)
        _z = _z - (p?.z ?? 0)
    }

    @objc(multiply:)
    public func multiply(_ a: Float) {
        _x = _x * a
        _y = _y * a
        _z = _z * a
    }

    public override var description: String {
        let desc = NSMutableString(capacity: 0)
        desc.append("Point3D (")
        desc.append(String(format: " %f,", Double(self.x)))
        desc.append(String(format: " %f,", Double(self.y)))
        desc.append(String(format: " %f )", Double(self.z)))
        return desc as String
    }

    /// The coordinates as "%f" strings under "x", "y" and "z".
    @objc public func exportToXML() -> NSMutableDictionary! {
        let xml = NSMutableDictionary()
        xml.setObject(NSString(format: "%f", Double(self.x)), forKey: "x" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.y)), forKey: "y" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.z)), forKey: "z" as NSString)
        return xml
    }

    /// A missing coordinate is 0, as -floatValue sent to nil was.
    @objc(initWithDictionary:)
    public convenience init(dictionary xml: [AnyHashable: Any]!) {
        self.init(xmlObject: xml as NSDictionary?)
    }

    /// -initWithDictionary: of whatever object the caller read: the
    /// coordinates are asked with -valueForKey:, which raises on an object that
    /// is not a dictionary, as it did.
    convenience init(xmlObject xml: Any?) {
        let object = xml as? NSObject
        self.init(x: Point3D.floatValue(object?.value(forKey: "x")),
                  y: Point3D.floatValue(object?.value(forKey: "y")),
                  z: Point3D.floatValue(object?.value(forKey: "z")))
    }

    /// -floatValue of a value read from a dictionary: an NSString or an NSNumber.
    static func floatValue(_ value: Any?) -> Float {
        guard let value = value else { return 0 }
        return (value as AnyObject).floatValue ?? 0
    }
}

/// The former category Point3D (N3GeometryAdditions).
extension Point3D {
    @objc(pointWithN3Vector:)
    public class func point(withN3Vector vector: N3Vector) -> Point3D {
        return Point3D(n3Vector: vector)
    }

    @objc(initWithN3Vector:)
    public convenience init(n3Vector vector: N3Vector) {
        self.init(x: Float(vector.x), y: Float(vector.y), z: Float(vector.z))
    }

    @objc(N3VectorValue)
    public func n3VectorValue() -> N3Vector {
        var vector = N3Vector()
        vector.x = CGFloat(self.x)
        vector.y = CGFloat(self.y)
        vector.z = CGFloat(self.z)
        return vector
    }
}
