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

/// Describes a 3D view state.
///
/// Camera saves the state of a 3D View to manage the vtkCamera, cropping
/// planes, window width and level, and 4D movie index.
///
/// The Objective-C name and selectors are those of the former class. The
/// properties are `dynamic`: the fly-thru table binds `index` and
/// `previewImage` of its cameras.
@objc(Camera)
public final class Camera: NSObject, NSCopying {
    // The former ivars. The initializers and -exportToXML use them directly,
    // as the Objective-C did; the properties are what the setters change.
    private var _position: Point3D?
    private var _viewUp: Point3D?
    private var _focalPoint: Point3D?
    /// Always a mutable array: VRView replaces the planes of the camera it
    /// fills in place.
    private var _croppingPlanes: NSMutableArray?
    private var _previewImage: NSImage?

    @objc public dynamic var index: Int32 = 0

    @objc public dynamic var position: Point3D! {
        get { return _position }
        set { _position = Camera.copied(newValue) }
    }

    @objc public dynamic var focalPoint: Point3D! {
        get { return _focalPoint }
        set { _focalPoint = Camera.copied(newValue) }
    }

    @objc public dynamic var viewUp: Point3D! {
        get { return _viewUp }
        set { _viewUp = Camera.copied(newValue) }
    }

    @objc public dynamic var croppingPlanes: NSMutableArray! {
        get { return _croppingPlanes }
        // A mutable copy: -copy of a mutable array is an immutable NSArray,
        // which the Objective-C kept under the NSMutableArray type, so
        // -replaceObjectAtIndex:withObject: on it raised.
        set { _croppingPlanes = Camera.mutableCopied(newValue) }
    }

    @objc public dynamic var previewImage: NSImage! {
        get { return _previewImage }
        set { _previewImage = newValue.map { unsafeBitCast($0.copy() as AnyObject, to: NSImage.self) } }
    }

    @objc public dynamic var is4D: Bool = false
    @objc public dynamic var forceUpdate: Bool = false
    @objc public dynamic var viewAngle: Float = 0
    @objc public dynamic var rollAngle: Float = 0
    @objc public dynamic var eyeAngle: Float = 0
    @objc public dynamic var parallelScale: Float = 0
    @objc public dynamic var clippingRangeNear: Float = 0
    @objc public dynamic var clippingRangeFar: Float = 0
    @objc public dynamic var ww: Float = 0
    @objc(LOD) public dynamic var lod: Float = 0
    @objc public dynamic var wl: Float = 0
    @objc public dynamic var fusionPercentage: Float = 0
    @objc public dynamic var movieIndexIn4D: Int = 0
    @objc public dynamic var windowCenterX: Float = 0
    @objc public dynamic var windowCenterY: Float = 0

    /// What a copy property setter stores: -copy of the value, nil for nil,
    /// unchecked as the Objective-C was.
    private static func copied(_ point: Point3D?) -> Point3D? {
        return point.map { unsafeBitCast($0.copy() as AnyObject, to: Point3D.self) }
    }

    /// A mutable copy of the planes, nil for nil.
    private static func mutableCopied(_ planes: NSArray?) -> NSMutableArray? {
        return planes.map { $0.mutableCopy() as! NSMutableArray }
    }

    @objc public override init() {
        _position = Point3D()
        _viewUp = Point3D()
        _focalPoint = Point3D()

        let planes = NSMutableArray()
        for _ in 0..<6 {
            planes.add(NSValue(n3Plane: N3PlaneInvalid)!)
        }
        _croppingPlanes = planes

        _previewImage = nil
        super.init()
    }

    /// Takes every property of the camera: copies of the points, the planes
    /// (mutable) and the preview image, and the index, the 4D state and movie
    /// index, the clipping range, the angles including the roll, the LOD,
    /// forceUpdate, the window and the fusion. -copy is this; the MPR undo
    /// restores such copies, and one that lost the movie index sent a 4D
    /// volume back to its first frame.
    @objc(initWithCamera:)
    public init(camera c: Camera!) {
        _position = Camera.copied(c?.position)
        _viewUp = Camera.copied(c?.viewUp)
        _focalPoint = Camera.copied(c?.focalPoint)
        _croppingPlanes = Camera.mutableCopied(c?.croppingPlanes)
        _previewImage = c?.previewImage.map { unsafeBitCast($0.copy() as AnyObject, to: NSImage.self) }
        super.init()
        index = c?.index ?? 0
        is4D = c?.is4D ?? false
        movieIndexIn4D = c?.movieIndexIn4D ?? 0
        rollAngle = c?.rollAngle ?? 0
        lod = c?.lod ?? 0
        forceUpdate = c?.forceUpdate ?? false
        clippingRangeNear = c?.clippingRangeNear ?? 0
        clippingRangeFar = c?.clippingRangeFar ?? 0
        viewAngle = c?.viewAngle ?? 0
        eyeAngle = c?.eyeAngle ?? 0
        parallelScale = c?.parallelScale ?? 0
        wl = c?.wl ?? 0
        ww = c?.ww ?? 0
        fusionPercentage = c?.fusionPercentage ?? 0
        windowCenterX = c?.windowCenterX ?? 0
        windowCenterY = c?.windowCenterY ?? 0
    }

    @objc(copyWithZone:)
    public func copy(with zone: NSZone?) -> Any {
        return Camera(camera: self)
    }

    @objc(setClippingRangeFrom:To:)
    public func setClippingRangeFrom(_ near: Float, to far: Float) {
        self.clippingRangeNear = near
        self.clippingRangeFar = far
    }

    // window level
    @objc(setWLWW::)
    public func setWLWW(_ newWl: Float, _ newWw: Float) {
        self.wl = newWl
        self.ww = newWw
    }

    public override var description: String {
        let desc = NSMutableString(capacity: 0)
        desc.append(String(format: "Position: %@\n", Camera.formatArgument(self.position)))
        desc.append(String(format: "ViewUp: %@\n", Camera.formatArgument(self.viewUp)))
        desc.append(String(format: "FocalPoint: %@\n", Camera.formatArgument(self.focalPoint)))
        desc.append(String(format: "clippingRangeNear: %f\n", Double(self.clippingRangeNear)))
        desc.append(String(format: "clippingRangeFar: %f\n", Double(self.clippingRangeFar)))
        desc.append(String(format: "viewAngle: %f\n", Double(self.viewAngle)))
        desc.append(String(format: "eyeAngle: %f\n", Double(self.eyeAngle)))
        desc.append(String(format: "parallelScale: %f\n", Double(self.parallelScale)))
        desc.append(String(format: "wl: %f\n", Double(self.wl)))
        desc.append(String(format: "ww: %f\n", Double(self.ww)))
        desc.append(String(format: "fusionPercentage: %f\n", Double(self.fusionPercentage)))
        return desc as String
    }

    /// %@ of nil prints "(null)".
    private static func formatArgument(_ object: NSObject?) -> NSObject {
        return object ?? ("(null)" as NSString)
    }

    @objc public func exportToXML() -> NSMutableDictionary! {
        let xml = NSMutableDictionary()

        Camera.setObject(_position?.exportToXML(), forKey: "position", in: xml)
        Camera.setObject(_viewUp?.exportToXML(), forKey: "viewUp", in: xml)
        Camera.setObject(_focalPoint?.exportToXML(), forKey: "focalPoint", in: xml)

        xml.setObject(NSString(format: "%f", Double(self.clippingRangeNear)), forKey: "clippingRangeNear" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.clippingRangeFar)), forKey: "clippingRangeFar" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.viewAngle)), forKey: "viewAngle" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.eyeAngle)), forKey: "eyeAngle" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.parallelScale)), forKey: "parallelScale" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.wl)), forKey: "wl" as NSString)
        xml.setObject(NSString(format: "%f", Double(self.ww)), forKey: "ww" as NSString)

        var i: Int32 = 0
        for element in _croppingPlanes ?? NSMutableArray() {
            // Sent as it was, unchecked: an object that is not an NSValue
            // raises the same unrecognized selector.
            let v = unsafeBitCast(element as AnyObject, to: NSValue.self)
            let representation = N3PlaneCreateDictionaryRepresentation(v.n3PlaneValue()).takeRetainedValue()
            xml.setObject(representation, forKey: NSString(format: "croppingPlanes %d", i))
            i += 1
        }

        xml.setObject(NSString(format: "%f", Double(self.fusionPercentage)), forKey: "fusionPercentage" as NSString)

        return xml
    }

    /// -setObject:forKey: of a point's -exportToXML: a point that is nil
    /// raises what -setObject:nil raised, which an Objective-C caller catches.
    private static func setObject(_ object: NSMutableDictionary?, forKey key: String, in xml: NSMutableDictionary) {
        guard let object = object else {
            NSException(name: .invalidArgumentException,
                        reason: "*** -[__NSDictionaryM setObject:forKey:]: object cannot be nil (key: \(key))",
                        userInfo: nil).raise()
            return
        }
        xml.setObject(object, forKey: key as NSString)
    }

    /// Implicitly unwrapped, as Swift saw the Objective-C initializer; it
    /// never fails.
    @objc(initWithDictionary:)
    public init!(dictionary xmlDictionary: [AnyHashable: Any]!) {
        let xml = xmlDictionary as NSDictionary?
        _position = Point3D(xmlObject: xml?.value(forKey: "position"))
        _viewUp = Point3D(xmlObject: xml?.value(forKey: "viewUp"))
        _focalPoint = Point3D(xmlObject: xml?.value(forKey: "focalPoint"))

        let planes = NSMutableArray(capacity: 6)
        for i in 0..<6 {
            var plane = N3PlaneInvalid
            let representation = xml?.object(forKey: NSString(format: "croppingPlanes %d", Int32(i)))
            if let representation = representation as? NSDictionary {
                _ = N3PlaneMakeWithDictionaryRepresentation(representation as CFDictionary, &plane)
            }
            planes.add(NSValue(n3Plane: plane)!)
        }
        _croppingPlanes = planes
        super.init()
        clippingRangeNear = Point3D.floatValue(xml?.value(forKey: "clippingRangeNear"))
        clippingRangeFar = Point3D.floatValue(xml?.value(forKey: "clippingRangeFar"))
        viewAngle = Point3D.floatValue(xml?.value(forKey: "viewAngle"))
        eyeAngle = Point3D.floatValue(xml?.value(forKey: "eyeAngle"))
        parallelScale = Point3D.floatValue(xml?.value(forKey: "parallelScale"))
        wl = Point3D.floatValue(xml?.value(forKey: "wl"))
        ww = Point3D.floatValue(xml?.value(forKey: "ww"))
        fusionPercentage = Point3D.floatValue(xml?.value(forKey: "fusionPercentage"))
    }
}
