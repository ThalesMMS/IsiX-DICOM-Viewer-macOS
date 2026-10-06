/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

// The second part of the "ww/wl" block of DCMView is implemented in Swift:
// the conversions between the view's and the image's coordinates, the
// geometry helpers, the orientation letters and the textual annotations. An
// extension of DCMView, which stays Objective-C, with the same selectors; their
// former declarations are in DCMView+WindowLevel.h, shared with the first part
// (DCMView+WindowLevel.swift).
//
// The conversions run per mouse event, and -drawOrientation: and
// -drawTextualData:... per frame: the instance variables are read once through
// their accessors where the Objective-C read them several times without a write
// in between, the C arrays are stack buffers, and the NSString properties that
// are only tested are read by message, without bridging them to String. The
// Swift strings left are those of the APIs Swift imports with String (the
// NSLocalizedString keys, -DrawNSStringGL:..., -isEqualToString:).

/// The OpenGL enumerant ROICanvasGL.h names, which Swift cannot import: that
/// header imports Horos-Swift.h.
private let GL_LINE_LOOP: UInt32 = 0x0002

// The static inline functions of ROICanvasGL.h, with the same parameter types.
private func roiBegin(_ mode: UInt32) { ROICanvas.current?.begin(mode) }
private func roiEnd() { ROICanvas.current?.end() }
private func roiVertex2f(_ x: Float, _ y: Float) { ROICanvas.current?.vertex(x: CGFloat(x), y: CGFloat(y)) }
private func roiColor3f(_ r: Float, _ g: Float, _ b: Float) {
    ROICanvas.current?.color(r: CGFloat(r), g: CGFloat(g), b: CGFloat(b), a: 1)
}
private func roiLineWidth(_ w: Float) { ROICanvas.current?.lineWidth(CGFloat(w)) }
private func roiLoadIdentity() { ROICanvas.current?.loadIdentity() }
private func roiScalef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.scale(x: Double(x), y: Double(y), z: Double(z)) }
private func roiTranslatef(_ x: Float, _ y: Float, _ z: Float) { ROICanvas.current?.translate(x: Double(x), y: Double(y), z: Double(z)) }

/// A floating-point value converted to int as the arm64 code of the C did
/// (fcvtzs): toward zero, saturated, NaN to 0; a Swift conversion traps instead.
@inline(__always)
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// The same, to long.
@inline(__always)
private func cLong(_ x: Double) -> Int {
    if x.isNaN { return 0 }
    if x >= 9223372036854775807.0 { return Int.max }
    if x <= -9223372036854775808.0 { return Int.min }
    return Int(x)
}

/// An object of an Objective-C collection or of an `id` result, to which the
/// Objective-C sent messages whatever its class: they are sent to it the same
/// way, so a malformed annotation raises the same NSException, which the
/// @catch of -drawTextualData:... reports.
@inline(__always)
private func objcObject<T: AnyObject>(_ object: Any, _ type: T.Type) -> T {
    return unsafeBitCast(object as AnyObject, to: T.self)
}

/// An `id` that may be nil, as an NSObject to send messages to.
@inline(__always)
private func objcObject(_ object: Any?) -> NSObject? {
    guard let object = object else { return nil }
    return unsafeBitCast(object as AnyObject, to: NSObject.self)
}

/// An object property read by message, as the Objective-C did, without
/// bridging an NSString to String; nil for a nil receiver.
@inline(__always)
private func objcProperty(_ receiver: NSObject?, _ getter: Selector) -> AnyObject? {
    return receiver?.perform(getter)?.takeUnretainedValue()
}

/// `[object isEqualToString: string]` of an `id`: NO for nil.
@inline(__always)
private func objcIsEqualToString(_ object: Any?, _ string: String) -> Bool {
    guard let object = object else { return false }
    return objcObject(object, NSString.self).isEqual(to: string)
}

/// An `id` that may be nil, as the NSArray the Objective-C sent it messages as.
@inline(__always)
private func objcArray(_ object: Any?) -> NSArray? {
    guard let object = object else { return nil }
    return unsafeBitCast(object as AnyObject, to: NSArray.self)
}

/// `[[dictionary objectForKey: key] intValue]` of the NSNumber dictionaries
/// -drawTextualData:... builds: 0 for a missing key.
@inline(__always)
private func intValue(_ dictionary: NSDictionary, _ key: Any) -> Int32 {
    return (dictionary.object(forKey: key) as? NSNumber)?.int32Value ?? 0
}

/// A "%@" argument: nil prints "(null)", as it did in a format.
private func arg(_ value: Any?) -> CVarArg {
    guard let value = value else { return "(null)" as NSString }
    return unsafeBitCast(value as AnyObject, to: NSObject.self)
}

/// N2LogExceptionWithStackTrace for an exception HorosObjCException caught.
private func logException(_ error: Error, _ function: StaticString) {
    guard let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException else { return }
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, true, $0.baseAddress) }
    }
}

// The keys of the annotation positions and of the dictionaries
// -drawTextualData:... builds per frame: constants, as the @"" of the
// Objective-C were. NSString is not Sendable, and only DCMView, which AppKit
// isolates to the main actor, reads them: they are isolated there.
@MainActor private let kTopLeft: NSString = "TopLeft"
@MainActor private let kMiddleLeft: NSString = "MiddleLeft"
@MainActor private let kLowerLeft: NSString = "LowerLeft"
@MainActor private let kTopRight: NSString = "TopRight"
@MainActor private let kMiddleRight: NSString = "MiddleRight"
@MainActor private let kLowerRight: NSString = "LowerRight"
@MainActor private let kTopMiddle: NSString = "TopMiddle"
@MainActor private let kLowerMiddle: NSString = "LowerMiddle"

private let kImageTypeGetter = #selector(getter: DCMPix.imageType)
private let kLateralityGetter = #selector(getter: DCMPix.laterality)
private let kMissingPixelsReasonGetter = #selector(getter: DCMPix.missingPixelsReason)
private let kViewPositionGetter = #selector(getter: DCMPix.viewPosition)
private let kPatientPositionGetter = #selector(getter: DCMPix.patientPosition)
private let kRetrieveStatusOverlay = #selector(ViewerController.retrieveStatusOverlay)

// Copyright 2001, softSurfer (www.softsurfer.com)
// This code may be freely used and modified for any purpose
// providing that this copyright notice is included with it.
// SoftSurfer makes no warranty for this code, and cannot be held
// liable for any real or imagined damage resulting from its use.
// Users of this code must verify correctness for their application.

// Assume that classes are already given for the objects:
//    Point and Vector with
//        coordinates {float x, y, z;}
//        operators for:
//            Point  = Point ± Vector
//            Vector = Point - Point
//            Vector = Scalar * Vector    (scalar product)
//    Plane with a point and a normal {Point V0; Vector n;}
//===================================================================

// dot product (3D) which allows vector operations in arguments
// (the dot and norm macros of the C: norm = length of vector, the square root
// of the float dot product computed in double)

@inline(__always)
private func dot(_ u: UnsafeMutablePointer<Float>, _ v: UnsafeMutablePointer<Float>) -> Float {
    return u[0] * v[0] + u[1] * v[1] + u[2] * v[2]
}

@inline(__always)
private func norm(_ v: UnsafeMutablePointer<Float>) -> Double {
    return sqrt(Double(dot(v, v)))
}

@inline(__always)
private func dot(_ u: UnsafeMutablePointer<Double>, _ v: UnsafeMutablePointer<Double>) -> Double {
    return u[0] * v[0] + u[1] * v[1] + u[2] * v[2]
}

@inline(__always)
private func norm(_ v: UnsafeMutablePointer<Double>) -> Double {
    return sqrt(dot(v, v))
}

extension DCMView {

    @objc(rotatePoint:)
    public dynamic func rotatePoint(_ a: NSPoint) -> NSPoint {
        var a = a
        let xx: Float, yy: Float
        let size = self.frame

        if self.horos_xFlipped { a.x = size.size.width - a.x }
        if self.horos_yFlipped { a.y = size.size.height - a.y }

        a.x -= size.size.width / 2
        //    a.x /= scaleValue;

        a.y -= size.size.height / 2
        //  a.y /= scaleValue;

        let angle = Double(self.horos_rotation) * DCMView.horos_static_deg2rad
        xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        let origin = self.horos_origin
        a.x -= (origin.x)
        a.y += (origin.y)

        a.x += CGFloat(Double(self.curDCM?.pwidth ?? 0) / 2.0)
        a.y += CGFloat(Double(self.curDCM?.pheight ?? 0) / 2.0)

        return a
    }

    @objc(ConvertFromGL2GL:toView:)
    public dynamic func convert(fromGL2GL a: NSPoint, to otherView: DCMView!) -> NSPoint {
        var a = self.convert(fromGL2View: a)
        a = otherView?.convert(fromView2GL: a) ?? .zero

        return a
    }

    @objc(ConvertFromGL2View:)
    public dynamic func convert(fromGL2View a: NSPoint) -> NSPoint {
        var a = a
        let size = self.horos_drawingFrameRect

        if self.curDCM != nil {
            a.y *= CGFloat(self.curDCM?.pixelRatio ?? 0)
            a.y -= CGFloat(Double(self.curDCM?.pheight ?? 0) * (self.curDCM?.pixelRatio ?? 0) * 0.5)
            a.x -= CGFloat(Float(self.curDCM?.pwidth ?? 0) * 0.5)
        }

        let scaleValue = CGFloat(self.horos_scaleValue)
        let origin = self.horos_origin
        a.y -= (origin.y) / scaleValue
        a.x += (origin.x) / scaleValue

        let angle = Double(-self.horos_rotation) * DCMView.horos_static_deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        a.y *= scaleValue
        a.y += size.size.height / 2.0

        a.x *= scaleValue
        a.x += size.size.width / 2.0

        if self.horos_xFlipped { a.x = size.size.width - a.x }
        if self.horos_yFlipped { a.y = size.size.height - a.y }

        a.x -= size.size.width / 2.0
        a.y -= size.size.height / 2.0

        return a
    }

    @objc(ConvertFromGL2NSView:)
    public dynamic func convert(fromGL2NSView a: NSPoint) -> NSPoint {
        var a = self.convert(fromGL2View: a)

        a.y = self.drawingFrameRect.size.height - a.y       // inverse Y scaling system
        a.y -= self.drawingFrameRect.size.height / 2.0      // Our viewing zero is centered in the view, NSView has the zero in left/bottom
        a.x += self.drawingFrameRect.size.width / 2.0

        a = self.convertFromBacking(a) //retina

        return a
    }

    @objc(ConvertFromGL2Screen:)
    public dynamic func convert(fromGL2Screen a: NSPoint) -> NSPoint {
        var a = self.convert(fromGL2NSView: a)
        a = self.convertToBacking(a)
        a = self.window?.convertToScreen(NSMakeRect(a.x, a.y, 0, 0)).origin ?? .zero
        return a
    }

    @objc(ConvertFromNSView2GL:)
    public dynamic func convert(fromNSView2GL a: NSPoint) -> NSPoint {
        var a = self.convertToBacking(a) //retina

        //inverse Y scaling system
        a.y = self.drawingFrameRect.size.height - a.y       // inverse Y scaling system

        return self.convert(fromUpLeftView2GL: a)
    }

    @objc(ConvertFromView2GL:)
    public dynamic func convert(fromView2GL a: NSPoint) -> NSPoint {
        var a = a
        a.x += self.drawingFrameRect.size.width / 2.0
        a.y += self.drawingFrameRect.size.height / 2.0

        return self.convert(fromUpLeftView2GL: a)
    }

    @objc(ConvertFromUpLeftView2GL:)
    public dynamic func convert(fromUpLeftView2GL a: NSPoint) -> NSPoint {
        var a = a
        let size = self.horos_drawingFrameRect
        let scaleValue = CGFloat(self.horos_scaleValue)

        if self.horos_xFlipped { a.x = size.size.width - a.x }
        if self.horos_yFlipped { a.y = size.size.height - a.y }

        a.x -= size.size.width / 2
        a.x /= scaleValue

        a.y -= size.size.height / 2
        a.y /= scaleValue

        let angle = Double(self.horos_rotation) * DCMView.horos_static_deg2rad
        let xx = Float(Double(a.x) * cos(angle) + Double(a.y) * sin(angle))
        let yy = Float(-Double(a.x) * sin(angle) + Double(a.y) * cos(angle))

        a.y = CGFloat(yy)
        a.x = CGFloat(xx)

        let origin = self.horos_origin
        a.x -= (origin.x) / scaleValue
        a.y += (origin.y) / scaleValue

        if self.curDCM != nil {
            a.x += CGFloat(Float(self.curDCM?.pwidth ?? 0) * 0.5)
            a.y += CGFloat(Double(self.curDCM?.pheight ?? 0) * (self.curDCM?.pixelRatio ?? 0) * 0.5)
            a.y /= CGFloat(self.curDCM?.pixelRatio ?? 0)
        }
        return a
    }

    @objc(positionWithoutRotation:)
    public dynamic func positionWithoutRotation(_ tPt: NSPoint) -> NSPoint {
        var tPt = tPt
        let scaleValue = CGFloat(self.horos_scaleValue)
        let deg2rad = DCMView.horos_static_deg2rad
        var unrotatedRect = NSMakeRect(tPt.x / scaleValue, tPt.y / scaleValue, 1, 1)
        var centeredRect = unrotatedRect

        var ratio: Float = 1

        if self.pixelSpacingX != 0 && self.pixelSpacingY != 0 {
            ratio = Float(self.pixelSpacingX / self.pixelSpacingY)
        }

        centeredRect.origin.y -= self.origin.y * CGFloat(ratio) / scaleValue
        centeredRect.origin.x -= -self.origin.x / scaleValue

        unrotatedRect.origin.x = centeredRect.origin.x * CGFloat(cos(Double(-self.rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(sin(Double(-self.rotation) * deg2rad)) / CGFloat(ratio)
        unrotatedRect.origin.y = -centeredRect.origin.x * CGFloat(sin(Double(-self.rotation) * deg2rad)) + centeredRect.origin.y * CGFloat(cos(Double(-self.rotation) * deg2rad)) / CGFloat(ratio)

        unrotatedRect.origin.y *= CGFloat(ratio)

        unrotatedRect.origin.y += self.origin.y * CGFloat(ratio) / scaleValue
        unrotatedRect.origin.x += -self.origin.x / scaleValue

        tPt = NSMakePoint(unrotatedRect.origin.x, unrotatedRect.origin.y)
        tPt.x = (tPt.x) * scaleValue - unrotatedRect.size.width / 2
        tPt.y = (tPt.y) / CGFloat(ratio) * scaleValue - unrotatedRect.size.height / 2 / CGFloat(ratio)

        return tPt
    }

    @objc public dynamic var pixelSpacing: Double { return self.curDCM?.pixelSpacingX ?? 0 }
    @objc public dynamic var pixelSpacingX: Double { return self.curDCM?.pixelSpacingX ?? 0 }
    @objc public dynamic var pixelSpacingY: Double { return self.curDCM?.pixelSpacingY ?? 0 }

    @objc(getOrientationText:::)
    public dynamic func getOrientationText(_ orientation: UnsafeMutablePointer<CChar>!, _ vector: UnsafeMutablePointer<Float>!, _ inv: Bool) {
        orientation[0] = 0

        let orientationX: String
        let orientationY: String
        let orientationZ: String

        let optr = NSMutableString()

        if inv {
            orientationX = -vector[0] < 0 ? NSLocalizedString("R", comment: "R: Right") : NSLocalizedString("L", comment: "L: Left")
            orientationY = -vector[1] < 0 ? NSLocalizedString("A", comment: "A: Anterior") : NSLocalizedString("P", comment: "P: Posterior")
            orientationZ = -vector[2] < 0 ? NSLocalizedString("I", comment: "I: Inferior") : NSLocalizedString("S", comment: "S: Superior")
        } else {
            orientationX = vector[0] < 0 ? NSLocalizedString("R", comment: "R: Right") : NSLocalizedString("L", comment: "L: Left")
            orientationY = vector[1] < 0 ? NSLocalizedString("A", comment: "A: Anterior") : NSLocalizedString("P", comment: "P: Posterior")
            orientationZ = vector[2] < 0 ? NSLocalizedString("I", comment: "I: Inferior") : NSLocalizedString("S", comment: "S: Superior")
        }

        var absX = Float(fabs(Double(vector[0])))
        var absY = Float(fabs(Double(vector[1])))
        var absZ = Float(fabs(Double(vector[2])))

        // get first 3 AXIS
        for _ in 0 ..< 3 {
            // The float is compared with the double .2, as in C.
            if Double(absX) > 0.2 && absX >= absY && absX >= absZ {
                optr.append(orientationX); absX = 0
            } else if Double(absY) > 0.2 && absY >= absX && absY >= absZ {
                optr.append(orientationY); absY = 0
            } else if Double(absZ) > 0.2 && absZ >= absX && absZ >= absY {
                optr.append(orientationZ); absZ = 0
            } else {
                break
            }
        }

        strcpy(orientation, optr.utf8String!)
    }

    // pbase_Plane(): get base of perpendicular from point to a plane
    //    Input:  P = a 3D point
    //            PL = a plane with point V0 and normal n
    //    Output: *B = base point on PL of perpendicular from P
    //    Return: the distance from P to the plane PL

    @objc(pbase_Plane::::)
    @discardableResult
    public dynamic class func pbase_Plane(_ point: UnsafeMutablePointer<Float>!, _ planeOrigin: UnsafeMutablePointer<Float>!, _ planeVector: UnsafeMutablePointer<Float>!, _ pointProjection: UnsafeMutablePointer<Float>!) -> Float {
        // float sub[ 3], on the stack.
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: 3) { subBuffer -> Float in
            let sb: Float, sn: Float, sd: Float
            let sub = subBuffer.baseAddress!

            sub[0] = point[0] - planeOrigin[0]
            sub[1] = point[1] - planeOrigin[1]
            sub[2] = point[2] - planeOrigin[2]

            sn = -dot(planeVector, sub)
            sd = dot(planeVector, planeVector)
            sb = sn / sd

            pointProjection[0] = point[0] + sb * planeVector[0]
            pointProjection[1] = point[1] + sb * planeVector[1]
            pointProjection[2] = point[2] + sb * planeVector[2]

            sub[0] = point[0] - pointProjection[0]
            sub[1] = point[1] - pointProjection[1]
            sub[2] = point[2] - pointProjection[2]

            return Float(norm(sub))
        }
    }

    @objc(angleBetweenVector:andVector:)
    public dynamic class func angleBetweenVector(_ v1: UnsafeMutablePointer<Float>!, andVector v2: UnsafeMutablePointer<Float>!) -> Float {
        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 && v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return 0
        }

        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 {
            return Float(DCMView.horos_static_deg2rad * 180)
        }

        if v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return Float(DCMView.horos_static_deg2rad * 180)
        }

        let cosTheta = Float(Double(dot(v1, v2)) / (norm(v1) * norm(v2)))

        return acosf(cosTheta)
    }

    @objc(angleBetweenVectorD:andVectorD:)
    public dynamic class func angleBetweenVectorD(_ v1: UnsafeMutablePointer<Double>!, andVectorD v2: UnsafeMutablePointer<Double>!) -> Double {
        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 && v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return 0
        }

        if v1[0] == 0 && v1[1] == 0 && v1[2] == 0 {
            return DCMView.horos_static_deg2rad * 180
        }

        if v2[0] == 0 && v2[1] == 0 && v2[2] == 0 {
            return DCMView.horos_static_deg2rad * 180
        }

        let cosTheta = dot(v1, v2) / (norm(v1) * norm(v2))

        return acos(cosTheta)
    }

    //===================================================================

    @objc(findPlaneAndPoint::)
    @discardableResult
    public dynamic func findPlaneAndPoint(_ pt: UnsafeMutablePointer<Float>!, _ location: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, localPoint: location, distanceWithPlane: nil)
    }

    /// Filters the input array of DCMPix by returning only the pix with the
    /// most common ImageType in the input array.
    @objc(cleanedOutDcmPixArray:)
    public dynamic class func cleanedOutDcmPixArray(_ input: NSArray!) -> NSArray! {
        var cleaned: NSArray? = nil
        do {
            try HorosObjCException.perform {
                // separate DCMPix into different arrays with common imageType
                let dcmPixByImageType = NSMutableDictionary()
                if let input = input {
                    for pix in input {
                        var pixImageType = objcProperty(objcObject(pix), kImageTypeGetter) as! NSString?
                        if pixImageType == nil { pixImageType = "" } // to avoid inserting nil keys in the dictionary
                        var dcmPixByImageTypeArray = dcmPixByImageType.object(forKey: pixImageType!) as! NSMutableArray?
                        if dcmPixByImageTypeArray == nil {
                            dcmPixByImageTypeArray = NSMutableArray()
                            dcmPixByImageType.setObject(dcmPixByImageTypeArray!, forKey: pixImageType!)
                        }
                        dcmPixByImageTypeArray!.add(pix)
                    }
                }

                // is there more than one imageType?
                if dcmPixByImageType.count > 1 {
                    // yes, find the most common one
                    var maxCountIndex = 0
                    let dcmPixByImageTypeArrays = dcmPixByImageType.allValues as NSArray
                    var i = 1
                    while i < dcmPixByImageType.count {
                        if objcObject(dcmPixByImageTypeArrays.object(at: i), NSArray.self).count > objcObject(dcmPixByImageTypeArrays.object(at: maxCountIndex), NSArray.self).count {
                            maxCountIndex = i
                        }
                        i += 1
                    }

                    // how many DCMPix have the most common imageType?
                    let maxCount = objcObject(dcmPixByImageTypeArrays.object(at: maxCountIndex), NSArray.self).count

                    // retain all DCMPix from groups with at least half the number of images with the most common imageType
                    let r = NSMutableArray()
                    if let input = input {
                        for pix in input {
                            let pixImageType = (objcProperty(objcObject(pix), kImageTypeGetter) as! NSString?) ?? ""
                            if (objcArray(dcmPixByImageType.object(forKey: pixImageType))?.count ?? 0) >= maxCount / 2 {
                                r.add(pix)
                            }
                        }
                    }

                    cleaned = r
                }
            }
        } catch {
            logException(error, "+[DCMView cleanedOutDcmPixArray:]")
            cleaned = nil
        }
        return cleaned ?? input
    }

    @objc(findPlaneForPoint:preferParallelTo:localPoint:distanceWithPlane:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, preferParallelTo parto: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, preferParallelTo: parto, localPoint: location, distanceWithPlane: distanceResult, preferImageType: nil)
    }

    @objc(findPlaneForPoint:preferParallelTo:localPoint:distanceWithPlane:preferImageType:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, preferParallelTo parto: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!, preferImageType preferredImageType: NSString!) -> Int32 {
        // float vectors[ 9], orig[ 3], locationTemp[ 3], on the stack.
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: 15) { buffer -> Int32 in
            buffer.initialize(repeating: 0)
            let vectors = buffer.baseAddress!
            let orig = vectors + 9
            let locationTemp = vectors + 12

            var ii: Int32 = -1
            var distance: Float = 999999
            var tempDistance: Float

            var vParallel = false

            if self.horos_cleanedOutDcmPixArray == nil {
                let cleaned: NSArray? = DCMView.cleanedOutDcmPixArray(self.horos_dcmPixList)
                if let cleaned = cleaned { _ = Unmanaged.passRetained(cleaned) }
                self.horos_cleanedOutDcmPixArray = cleaned
            }
            let cleanedOutDcmPixArray = self.horos_cleanedOutDcmPixArray
            let volumicData = self.horos_volumicData

            var currParallel = false
            if volumicData == 1 { // All planes have the same orientation : we can compute currParallel only once !
                (cleanedOutDcmPixArray?.lastObject as! DCMPix?)?.orientation(vectors)
                if parto != nil && DCMView.angleBetweenVector(parto + 6, andVector: vectors + 6) < UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") { // are parallel!
                    currParallel = true
                }
            }

            var selectedPix: DCMPix? = nil
            if let cleanedOutDcmPixArray = cleanedOutDcmPixArray {
                for element in cleanedOutDcmPixArray {
                    let pix = objcObject(element, DCMPix.self)
                    if volumicData != 1 {
                        pix.orientation(vectors)

                        if parto != nil && DCMView.angleBetweenVector(parto + 6, andVector: vectors + 6) < UserDefaults.standard.float(forKey: "PARALLELPLANETOLERANCE") { // are parallel!
                            currParallel = true
                        } else {
                            currParallel = false
                        }
                    }

                    pix.origin(orig)
                    tempDistance = DCMView.pbase_Plane(pt, orig, vectors + 6, locationTemp)

                    // Both are NSString: -isEqual: answers as -isEqualToString:,
                    // without bridging them to String.
                    let matchingType = (preferredImageType?.length ?? 0) != 0 && ((objcProperty(pix, kImageTypeGetter) as! NSString?)?.isEqual(preferredImageType) ?? false)
                    let selectedMatchingType = (preferredImageType?.length ?? 0) != 0 && ((objcProperty(selectedPix, kImageTypeGetter) as! NSString?)?.isEqual(preferredImageType) ?? false)
                    if (!vParallel && currParallel) || (currParallel == vParallel &&
                        (tempDistance < distance || (tempDistance == distance && matchingType && !selectedMatchingType))) {
                        vParallel = currParallel

                        if location != nil {
                            location[0] = locationTemp[0]
                            location[1] = locationTemp[1]
                            location[2] = locationTemp[2]
                        }

                        distance = tempDistance
                        selectedPix = pix
                    }
                }
            }

            // Filtering by image type can reorder pixels or remove earlier instances.
            // Callers index dcmPixList, so resolve the selected object in that array.
            if let selectedPix = selectedPix {
                // A message to a nil dcmPixList answers 0, as it did.
                let originalIndex = self.horos_dcmPixList?.indexOfObjectIdentical(to: selectedPix) ?? 0
                if originalIndex != NSNotFound {
                    ii = Int32(truncatingIfNeeded: originalIndex)
                }
            }

            if ii != -1 {
                if (self.curDCM?.sliceThickness ?? 0) != 0 && Double(distance) > (self.curDCM?.sliceThickness ?? 0) * 2 { ii = -1 }
            }

            if let distanceResult = distanceResult {
                distanceResult.pointee = distance
            }

            return ii
        }
    }

    @objc(findPlaneForPoint:localPoint:distanceWithPlane:)
    @discardableResult
    public dynamic func findPlane(forPoint pt: UnsafeMutablePointer<Float>!, localPoint location: UnsafeMutablePointer<Float>!, distanceWithPlane distanceResult: UnsafeMutablePointer<Float>!) -> Int32 {
        return self.findPlane(forPoint: pt, preferParallelTo: nil, localPoint: location, distanceWithPlane: distanceResult)
    }

    @objc(drawOrientation:)
    public dynamic func drawOrientation(_ size: NSRect) {
        var size = size
        let screenCaptureRect = self.horos_screenCaptureRect
        if NSIsEmptyRect(screenCaptureRect) == false {
            size = screenCaptureRect
        } else {
            size.origin = NSMakePoint(0, 0)
        }

        let stringSize = self.horos_stringSize

        // Determine Anterior, Posterior, Left, Right, Head, Foot
        // char string[ 10]; float vectors[ 9];, on the stack.
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 10) { stringBuffer in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 9) { vectorsBuffer in
                stringBuffer.initialize(repeating: 0)
                vectorsBuffer.initialize(repeating: 0)
                let string = stringBuffer.baseAddress!
                let vectors = vectorsBuffer.baseAddress!

                self.orientationCorrected(toView: vectors)

                // Left
                self.getOrientationText(string, vectors, true)
                self.drawCStringGL(string, DCMViewMainFont, cLong(Double(size.origin.x + 6)), cLong(Double(size.origin.y + 2 + size.size.height / 2)), rightAlignment: false, useStringTexture: true)

                // Right
                self.getOrientationText(string, vectors, false)
                self.drawCStringGL(string, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width - (2 + stringSize.width * CGFloat(strlen(string))))), cLong(Double(size.origin.y + 2 + size.size.height / 2)), rightAlignment: false, useStringTexture: true)

                //Top
                var yPosition = Float(size.origin.y + stringSize.height + 3)
                self.getOrientationText(string, vectors + 3, true)

                if strlen(string) != 0 {
                    self.drawCStringGL(string, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2 - (stringSize.width * CGFloat(strlen(string)) / 2))), cLong(Double(yPosition)), rightAlignment: false, useStringTexture: true)
                    yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                }

                if objcProperty(self.curDCM, kLateralityGetter) != nil {
                    self.drawNSStringGL(objcProperty(self.curDCM, kLateralityGetter) as! NSString? as String?, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                    yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                }

                let xFlipped = self.horos_xFlipped
                let yFlipped = self.horos_yFlipped
                if self.is2DViewer() && (xFlipped || yFlipped) {
                    var flippedString: String? = nil

                    if xFlipped && yFlipped {
                        flippedString = NSLocalizedString("Horizontally & Vertically Flipped", comment: "")
                    } else if xFlipped {
                        flippedString = NSLocalizedString("Horizontally Flipped", comment: "")
                    } else if yFlipped {
                        flippedString = NSLocalizedString("Vertically Flipped", comment: "")
                    }

                    if let flippedString = flippedString {
                        self.drawNSStringGL(flippedString, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                        yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                    }
                }

                if self.is2DViewer() && (self.curDCM?.voilutApplied ?? false) {
                    self.drawNSStringGL("VOI LUT Applied", DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                    yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                }

                // An empty frame is otherwise indistinguishable from a dark one, and the
                // only thing that said which it was went to the console.
                if ((objcProperty(self.curDCM, kMissingPixelsReasonGetter) as! NSString?)?.length ?? 0) != 0 {
                    self.drawNSStringGL(objcProperty(self.curDCM, kMissingPixelsReasonGetter) as! NSString? as String?, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                    yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                }

                // A series still being received, or received short, says so on the image:
                // an open viewer is not a finished retrieve.
                if self.is2DViewer() && (objcObject(self.windowController())?.responds(to: kRetrieveStatusOverlay) ?? false) {
                    let receiving = objcProperty(objcObject(self.windowController()), kRetrieveStatusOverlay) as! NSString?
                    if (receiving?.length ?? 0) != 0 {
                        self.drawNSStringGL(receiving as String?, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                        yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                    }
                }

                if self.is2DViewer() && (self.window?.isKeyWindow ?? false) == false {
                    let overlay = ViewerReferenceLines.overlayText(displayingLines: DISPLAYCROSSREFERENCELINES != 0,
                                                                  annotationType: Int(self.horos_annotationType))
                    if !(overlay ?? "").isEmpty {
                        self.drawNSStringGL(overlay, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(yPosition)), align: DCMViewTextAlignCenter, useStringTexture: true)
                        yPosition = Float(CGFloat(yPosition) + (stringSize.height + 3))
                    }
                }

                //Bottom
                self.getOrientationText(string, vectors + 3, false)
                self.drawCStringGL(string, DCMViewMainFont, cLong(Double(size.origin.x + size.size.width / 2)), cLong(Double(size.origin.y + 2 + size.size.height - 6)), rightAlignment: false, useStringTexture: true)
            }
        }
    }

    @objc(getThickSlabThickness:location:)
    public dynamic func getThickSlabThickness(_ thickness: UnsafeMutablePointer<Float>!, location: UnsafeMutablePointer<Float>!) {
        thickness.pointee = Float(self.curDCM?.sliceThickness ?? 0)
        location.pointee = Float(self.curDCM?.sliceLocation ?? 0)
        let curImage = Int(self.horos_curImage)
        let dcmPixList = self.horos_dcmPixList
        if curImage < 0 || curImage >= (dcmPixList?.count ?? 0) || (self.curDCM?.stack ?? 0) <= 1 {
            return
        }

        // Location zero is a valid physical plane. Clip the slab to available
        // slices in its actual projection direction, including both end slices.
        let available: Int = self.horos_flippedData ? curImage + 1 : dcmPixList!.count - curImage
        let stack = Int(self.curDCM?.stack ?? 0)
        let count = stack < available ? stack : available
        let last = curImage + (self.horos_flippedData ? -1 : 1) * (count - 1)
        let endLocation: Double = objcObject(dcmPixList!.object(at: last), DCMPix.self).sliceLocation
        if location.pointee.isFinite && endLocation.isFinite {
            thickness.pointee = Float(Double(thickness.pointee) + fabs(endLocation - Double(location.pointee)))
            location.pointee = Float((Double(location.pointee) + endLocation) / 2.0)
        }
    }

    @objc(displayedScaleValue)
    dynamic func displayedScaleValue() -> Float {
        return self.horos_scaleValue
    }

    @objc(displayedRotation)
    dynamic func displayedRotation() -> Float {
        return self.horos_rotation
    }

    @objc(drawTextualData:annotationsLevel:fullText:onlyOrientation:)
    public dynamic func drawTextualData(_ size: NSRect, annotationsLevel annotations: Int, fullText: Bool, onlyOrientation: Bool) {
        var size = size
        let sf = Float(self.window?.backingScaleFactor ?? 0) //retina


        //** TEXT INFORMATION
        roiLoadIdentity() // reset model view matrix to identity (eliminates rotation basically)
        roiScalef(Float(2.0 / size.size.width), Float(-2.0 / size.size.height), 1.0) // scale to port per pixel scale
        roiTranslatef(Float(-(size.size.width) / 2.0), Float(-(size.size.height) / 2.0), 0.0) // translate center to upper left

        //draw line around edge for key Images only in 2D Viewer

        if self.isKeyImage() && self.horos_stringID == nil {
            roiLineWidth(Float(8.0 * (self.window?.backingScaleFactor ?? 0)))
            roiColor3f(1.0, 1.0, 0.0)
            roiBegin(GL_LINE_LOOP)
            roiVertex2f(0.0, 0.0)
            roiVertex2f(0.0, Float(size.size.height - 0.0))
            roiVertex2f(Float(size.size.width - 0.0), Float(size.size.height - 0.0))
            roiVertex2f(Float(size.size.width - 0.0), 0.0)
            roiEnd()
        }

        roiColor3f(0.0, 0.0, 0.0)
        roiLineWidth(Float(1.0 * (self.window?.backingScaleFactor ?? 0)))

        let fontList: DCMViewFontKind = DCMViewMainFont
        let stringSize = self.horos_stringSize

        if annotations == 4 {
            NotificationCenter.default.post(name: .OsirixDrawTextInfo, object: self)
        } else if annotations > annotGraphics {
            let screenCaptureRect = self.horos_screenCaptureRect
            if NSIsEmptyRect(screenCaptureRect) == false {
                size = screenCaptureRect
            } else {
                size.origin = NSMakePoint(0, 0)
            }

            var yRaster = 1, xRaster = 0

            if onlyOrientation {
                self.drawOrientation(size)
                return
            }

            var colorBoxSize: Int32 = 0

            if self.horos_studyColorR != 0 || self.horos_studyColorG != 0 || self.horos_studyColorB != 0 {
                colorBoxSize = cInt32(Double(30 * sf))
            }

            if colorBoxSize != 0 && self.horos_stringID == nil && self.is2DViewer() == true {
                if self.horos_studyDateBox == nil && self.horos_studyDateIndex != UInt(NSNotFound) {
                    let boxColor = NSColor(calibratedRed: CGFloat(self.horos_studyColorR), green: CGFloat(self.horos_studyColorG), blue: CGFloat(self.horos_studyColorB), alpha: 1.0)

                    let stanStringAttrib: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 20)!]
                    let studyDateIndex = self.horos_studyDateIndex
                    let box: AnnotationBox
                    if studyDateIndex &+ 1 < 10 {
                        box = AnnotationBox(attributedString: NSAttributedString(string: NSString(format: " %d ", Int32(truncatingIfNeeded: studyDateIndex) &+ 1) as String, attributes: stanStringAttrib), boxColor: boxColor, borderColor: boxColor)
                    } else {
                        box = AnnotationBox(attributedString: NSAttributedString(string: NSString(format: "%d", Int32(truncatingIfNeeded: studyDateIndex) &+ 1) as String, attributes: stanStringAttrib), boxColor: boxColor, borderColor: boxColor)
                    }
                    // The ivar owns the box, as the alloc/init did.
                    _ = Unmanaged.passRetained(box)
                    self.horos_studyDateBox = box
                }

                if let studyDateBox = self.horos_studyDateBox {
                    let boxSize = self.convertToBacking(studyDateBox.frameSize)
                    self.horosDraw(studyDateBox, bounds: NSMakeRect(size.origin.x + CGFloat(5 * sf), size.origin.y + CGFloat(4 * sf), boxSize.width, boxSize.height))
                }
            } else {
                colorBoxSize = 0
            }

            let annotationsDictionary: NSMutableDictionary? = self.curDCM?.annotationsDictionary

            let xRasterInit = NSMutableDictionary()
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + (6 + self.horosScrollPreviewAnnotationInset()) * CGFloat(sf)))), forKey: kTopLeft)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + CGFloat(6 * sf)))), forKey: kMiddleLeft)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + CGFloat(6 * sf)))), forKey: kLowerLeft)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + size.size.width - CGFloat(2 * sf)))), forKey: kTopRight)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + size.size.width - CGFloat(2 * sf)))), forKey: kMiddleRight)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + size.size.width - CGFloat(2 * sf)))), forKey: kLowerRight)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + size.size.width / 2))), forKey: kTopMiddle)
            xRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.x + size.size.width / 2))), forKey: kLowerMiddle)

            let alignLeft = NSNumber(value: Int32(bitPattern: DCMViewTextAlignLeft.rawValue))
            let alignRight = NSNumber(value: Int32(bitPattern: DCMViewTextAlignRight.rawValue))
            let alignCenter = NSNumber(value: Int32(bitPattern: DCMViewTextAlignCenter.rawValue))
            let align = NSMutableDictionary()
            align.setObject(alignLeft, forKey: kTopLeft)
            align.setObject(alignLeft, forKey: kMiddleLeft)
            align.setObject(alignLeft, forKey: kLowerLeft)
            align.setObject(alignRight, forKey: kTopRight)
            align.setObject(alignRight, forKey: kMiddleRight)
            align.setObject(alignRight, forKey: kLowerRight)
            align.setObject(alignCenter, forKey: kTopMiddle)
            align.setObject(alignCenter, forKey: kLowerMiddle)

            let yRasterInit = NSMutableDictionary()
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + stringSize.height + CGFloat(2 * sf)))), forKey: kTopLeft)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + stringSize.height))), forKey: kTopMiddle)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + stringSize.height + CGFloat(2 * sf)))), forKey: kTopRight)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + size.size.height / 2))), forKey: kMiddleLeft)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + size.size.height / 2))), forKey: kMiddleRight)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + size.size.height - CGFloat(2 * sf)))), forKey: kLowerLeft)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + size.size.height - CGFloat(2 * sf) - stringSize.height))), forKey: kLowerRight)
            yRasterInit.setObject(NSNumber(value: cInt32(Double(size.origin.y + size.size.height - CGFloat(2 * sf)))), forKey: kLowerMiddle)

            let lineUp = NSNumber(value: cInt32(Double(stringSize.height)))
            let lineDown = NSNumber(value: cInt32(Double(-stringSize.height)))
            let yRasterIncrement = NSMutableDictionary()
            yRasterIncrement.setObject(lineUp, forKey: kTopLeft)
            yRasterIncrement.setObject(lineUp, forKey: kTopMiddle)
            yRasterIncrement.setObject(lineUp, forKey: kTopRight)
            yRasterIncrement.setObject(lineUp, forKey: kMiddleLeft)
            yRasterIncrement.setObject(lineUp, forKey: kMiddleRight)
            yRasterIncrement.setObject(lineDown, forKey: kLowerLeft)
            yRasterIncrement.setObject(lineDown, forKey: kLowerRight)
            yRasterIncrement.setObject(lineDown, forKey: kLowerMiddle)


            var increment: Int32 = 0
            let orientationPositionKeys = NSArray(objects: kTopMiddle, kMiddleLeft, kMiddleRight, kLowerMiddle)
            var orientationDrawn = false
            do {
                var k = 0
                while k < orientationPositionKeys.count {
                    let positionKey = objcObject(orientationPositionKeys.object(at: k), NSString.self)
                    let annotationsOfPosition = objcArray(annotationsDictionary?.object(forKey: positionKey))
                    xRaster = Int(intValue(xRasterInit, positionKey))
                    yRaster = Int(intValue(yRasterInit, positionKey))
                    increment = intValue(yRasterIncrement, positionKey)

                    let enumerator: NSEnumerator?
                    if positionKey.hasPrefix("Lower") {
                        enumerator = annotationsOfPosition?.reverseObjectEnumerator()
                    } else {
                        enumerator = annotationsOfPosition?.objectEnumerator()
                    }

                    while let annot = enumerator?.nextObject() {
                        let annotArray = objcObject(annot, NSArray.self)
                        var j = 0
                        while j < annotArray.count {
                            if objcObject(annotArray.object(at: j), NSString.self).isEqual(to: "Orientation") {
                                if !orientationDrawn {
                                    self.drawOrientation(size)
                                }
                                orientationDrawn = true
                            }
                            j += 1
                        }
                    }
                    k += 1
                }
            }

            if orientationDrawn {
                yRasterInit.setObject(NSNumber(value: intValue(yRasterInit, kTopMiddle) &+ intValue(yRasterIncrement, kTopMiddle)), forKey: kTopMiddle)
                yRasterInit.setObject(NSNumber(value: intValue(yRasterInit, kMiddleLeft) &+ intValue(yRasterIncrement, kMiddleLeft)), forKey: kMiddleLeft)
                yRasterInit.setObject(NSNumber(value: intValue(yRasterInit, kMiddleRight) &+ intValue(yRasterIncrement, kMiddleRight)), forKey: kMiddleRight)
                yRasterInit.setObject(NSNumber(value: intValue(yRasterInit, kLowerMiddle) &+ intValue(yRasterIncrement, kLowerMiddle)), forKey: kLowerMiddle)
            }

            let keys: NSArray? = annotationsDictionary?.allKeys as NSArray?

            var k = 0
            while k < (keys?.count ?? 0) {
                let key = objcObject(keys!.object(at: k), NSString.self)

                let annotationsOfKey = objcArray(annotationsDictionary?.object(forKey: key))
                xRaster = Int(intValue(xRasterInit, key)) //* [self.window backingScaleFactor]; //Retina
                yRaster = Int(intValue(yRasterInit, key)) //* [self.window backingScaleFactor]; //Retina
                increment = intValue(yRasterIncrement, key) // * [self.window backingScaleFactor]; //retina

                var enumerator: NSEnumerator?
                if key.hasPrefix("Lower") {
                    enumerator = annotationsOfKey?.reverseObjectEnumerator()
                } else {
                    enumerator = annotationsOfKey?.objectEnumerator()
                }

                let useStringTexture = true // HOROS-535 setting to NO causes annotations to be MIA

                if key.hasPrefix("Lower") {
                    enumerator = annotationsOfKey?.reverseObjectEnumerator()
                } else {
                    enumerator = annotationsOfKey?.objectEnumerator()
                }

                while let annot = enumerator?.nextObject() {
                    do {
                        try HorosObjCException.perform { () -> Void in
                            let tempString = NSMutableString(string: "")
                            let tempString2 = NSMutableString(string: "")
                            let tempString3 = NSMutableString(string: "")
                            let tempString4 = NSMutableString(string: "")
                            let annotArray = objcObject(annot, NSArray.self)
                            var j = 0
                            while j < annotArray.count {
                                // [annot objectAtIndex:j], which the Objective-C
                                // sent again for each comparison.
                                let item = objcObject(annotArray.object(at: j), NSString.self)
                                if item.isEqual(to: "Image Size") && fullText {
                                    tempString.appendFormat(NSLocalizedString("Image size: %ld x %ld", comment: "") as NSString, self.curDCM?.pwidth ?? 0, self.curDCM?.pheight ?? 0)
                                } else if item.isEqual(to: "View Size") && fullText {
                                    tempString.appendFormat(NSLocalizedString("View size: %ld x %ld", comment: "") as NSString, cLong(Double(size.size.width)), cLong(Double(size.size.height)))
                                } else if item.isEqual(to: "Mouse Position (px)") {
                                    let stringID = self.horos_stringID
                                    if (stringID?.length ?? 0) == 0 || (stringID?.isEqual(to: "previewDatabase") ?? false) {
                                        //                                if(mouseXPos!=0 || mouseYPos!=0)
                                        do {
                                            var pixelUnit: NSString = ""

                                            if self.curDCM?.suvConverted ?? false {
                                                pixelUnit = "SUV"
                                            }

                                            if self.curDCM?.isRGB ?? false {
                                                tempString.appendFormat(NSLocalizedString("X: %d px Y: %d px Value: R:%ld G:%ld B:%ld", comment: "No special characters for this string, only ASCII characters.") as NSString, cInt32(Double(self.horos_mouseXPos)), cInt32(Double(self.horos_mouseYPos)), self.horos_pixelMouseValueR, self.horos_pixelMouseValueG, self.horos_pixelMouseValueB)
                                            } else {
                                                tempString.appendFormat(NSLocalizedString("X: %d px Y: %d px Value: %2.2f %@", comment: "No special characters for this string, only ASCII characters.") as NSString, cInt32(Double(self.horos_mouseXPos)), cInt32(Double(self.horos_mouseYPos)), Double(self.horos_pixelMouseValue), pixelUnit)
                                            }

                                            if let blendingView = self.horos_blending {
                                                if blendingView.curDCM?.suvConverted ?? false {
                                                    pixelUnit = "SUV"
                                                }

                                                if blendingView.curDCM?.isRGB ?? false {
                                                    tempString2.appendFormat(NSLocalizedString("Fused Image : X: %d px Y: %d px Value: R:%ld G:%ld B:%ld", comment: "No special characters for this string, only ASCII characters.") as NSString, cInt32(Double(self.horos_blendingMouseXPos)), cInt32(Double(self.horos_blendingMouseYPos)), self.horos_blendingPixelMouseValueR, self.horos_blendingPixelMouseValueG, self.horos_blendingPixelMouseValueB)
                                                } else {
                                                    tempString2.appendFormat(NSLocalizedString("Fused Image : X: %d px Y: %d px Value: %2.2f %@", comment: "No special characters for this string, only ASCII characters.") as NSString, cInt32(Double(self.horos_blendingMouseXPos)), cInt32(Double(self.horos_blendingMouseYPos)), Double(self.horos_blendingPixelMouseValue), pixelUnit)
                                                }
                                            }

                                            if self.curDCM?.displaySUVValue ?? false {
                                                if (self.curDCM?.hasSUV ?? false) == true && (self.curDCM?.suvConverted ?? false) == false {
                                                    tempString3.appendFormat(NSLocalizedString("SUV: %.2f", comment: "SUV: Standard Uptake Value - No special characters for this string, only ASCII characters.") as NSString, Double(self.getSUV()))
                                                }
                                            }

                                            if let blendingView = self.horos_blending {
                                                if (blendingView.curDCM?.displaySUVValue ?? false) && (blendingView.curDCM?.hasSUV ?? false) && (blendingView.curDCM?.suvConverted ?? false) == false {
                                                    tempString4.appendFormat(NSLocalizedString("SUV (fused image): %.2f", comment: "SUV: Standard Uptake Value - No special characters for this string, only ASCII characters.") as NSString, Double(self.getBlendedSUV()))
                                                }
                                            }
                                        }
                                    }
                                } else if item.isEqual(to: "Zoom") && fullText {
                                    tempString.appendFormat(NSLocalizedString("Zoom: %0.0f%%", comment: "No special characters for this string, only ASCII characters.") as NSString, Double(self.displayedScaleValue()) * 100.0)
                                } else if item.isEqual(to: "Rotation Angle") && fullText {
                                    tempString.appendFormat(NSLocalizedString(" Angle: %0.0f", comment: "No special characters for this string, only ASCII characters.") as NSString, Double(Float(cLong(Double(self.displayedRotation())) % 360)))
                                } else if item.isEqual(to: "Image Position") && fullText {
                                    var orientationStack: NSString = ""
                                    if self.is2DViewer() && (self.windowController() as? ViewerController)?.isEverythingLoaded() == true {
                                        if self.horos_volumicData == -1 {
                                            self.horos_volumicData = ((self.windowController() as? ViewerController)?.isDataVolumicIn4D(true, checkEverythingLoaded: true, tryToCorrect: false) ?? false) ? 1 : 0
                                        }

                                        let dcmPixList = self.horos_dcmPixList
                                        if self.horos_volumicSeries == true && (dcmPixList?.count ?? 0) > 2 && self.horos_volumicData == 1 {
                                            let interval3d: Double
                                            let pix2 = objcObject(dcmPixList!.object(at: 2), DCMPix.self)
                                            let pix1 = objcObject(dcmPixList!.object(at: 1), DCMPix.self)
                                            var xd = pix2.originX - pix1.originX // To avoid the problem with 1st scout image
                                            var yd = pix2.originY - pix1.originY
                                            var zd = pix2.originZ - pix1.originZ

                                            interval3d = sqrt(xd * xd + yd * yd + zd * zd)
                                            xd /= interval3d; yd /= interval3d; zd /= interval3d

                                            // float v[ 3]; char stackOrientationStart[ 10], stackOrientationEnd[ 10];
                                            withUnsafeTemporaryAllocation(of: Float.self, capacity: 3) { vBuffer in
                                                withUnsafeTemporaryAllocation(of: CChar.self, capacity: 20) { textBuffer in
                                                    textBuffer.initialize(repeating: 0)
                                                    let v = vBuffer.baseAddress!
                                                    v[0] = Float(xd); v[1] = Float(yd); v[2] = Float(zd)
                                                    let stackOrientationStart = textBuffer.baseAddress!
                                                    let stackOrientationEnd = stackOrientationStart + 10
                                                    if self.horos_flippedData == false {
                                                        self.getOrientationText(stackOrientationStart, v, true)
                                                        self.getOrientationText(stackOrientationEnd, v, false)
                                                    } else {
                                                        self.getOrientationText(stackOrientationStart, v, false)
                                                        self.getOrientationText(stackOrientationEnd, v, true)
                                                    }

                                                    if stackOrientationStart[0] != 0 && stackOrientationEnd[0] != 0 {
                                                        let pos: Float
                                                        let pixCount = dcmPixList!.count

                                                        if self.horos_flippedData {
                                                            pos = Float(UInt(bitPattern: pixCount) &- UInt(bitPattern: Int(self.horos_curImage))) / Float(pixCount)
                                                        } else {
                                                            pos = Float(self.horos_curImage) / Float(pixCount)
                                                        }

                                                        // The float compared with the doubles 0.4 and 0.6, as in C.
                                                        if Double(pos) < 0.4 {
                                                            orientationStack = NSString(format: " %c (%c -> %c)", Int32(stackOrientationStart[0]), Int32(stackOrientationStart[0]), Int32(stackOrientationEnd[0]))
                                                        } else if Double(pos) > 0.6 {
                                                            orientationStack = NSString(format: " %c (%c -> %c)", Int32(stackOrientationEnd[0]), Int32(stackOrientationStart[0]), Int32(stackOrientationEnd[0]))
                                                        } else {
                                                            orientationStack = NSString(format: " (%c -> %c)", Int32(stackOrientationStart[0]), Int32(stackOrientationEnd[0]))
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    let curImage = Int(self.horos_curImage)
                                    let pixCount = self.horos_dcmPixList?.count ?? 0
                                    if (self.curDCM?.stack ?? 0) > 1 {
                                        var maxVal: Int

                                        if self.horos_flippedData {
                                            maxVal = curImage - Int(self.curDCM?.stack ?? 0) + 1
                                        } else {
                                            maxVal = curImage + Int(self.curDCM?.stack ?? 0)
                                        }

                                        if maxVal < 0 { maxVal = 0 }
                                        if maxVal > pixCount { maxVal = pixCount }

                                        if self.horos_flippedData {
                                            tempString.appendFormat(NSLocalizedString("Im: %ld-%ld/%ld %@", comment: "No special characters for this string, only ASCII characters.") as NSString, pixCount - curImage, pixCount &- maxVal, pixCount, orientationStack)
                                        } else {
                                            tempString.appendFormat(NSLocalizedString("Im: %ld-%ld/%ld %@", comment: "No special characters for this string, only ASCII characters.") as NSString, curImage + 1, maxVal, pixCount, orientationStack)
                                        }
                                    } else if fullText {
                                        if self.horos_flippedData {
                                            tempString.appendFormat(NSLocalizedString("Im: %ld/%ld %@", comment: "No special characters for this string, only ASCII characters.") as NSString, pixCount - curImage, pixCount, orientationStack)
                                        } else {
                                            tempString.appendFormat(NSLocalizedString("Im: %ld/%ld %@", comment: "No special characters for this string, only ASCII characters.") as NSString, curImage + 1, pixCount, orientationStack)
                                        }
                                    }
                                } else if item.isEqual(to: "Mouse Position (mm)") {
                                    if self.horos_stringID == nil {
                                        //								if( mouseXPos != 0 || mouseYPos != 0)
                                        do {
                                            var location: (Float, Float, Float) = (0, 0, 0)

                                            withUnsafeMutablePointer(to: &location) { locationTuple in
                                                locationTuple.withMemoryRebound(to: Float.self, capacity: 3) { locationPointer in
                                                    if (self.curDCM?.stack ?? 0) > 1 {
                                                        var maxVal: Int
                                                        let curImage = Int(self.horos_curImage)

                                                        if self.horos_flippedData {
                                                            maxVal = curImage - (Int(self.curDCM?.stack ?? 0) - 1) / 2
                                                        } else {
                                                            maxVal = curImage + (Int(self.curDCM?.stack ?? 0) - 1) / 2
                                                        }

                                                        let dcmPixList = self.horos_dcmPixList
                                                        if maxVal < 0 { maxVal = 0 }
                                                        if maxVal >= (dcmPixList?.count ?? 0) { maxVal = (dcmPixList?.count ?? 0) - 1 }

                                                        if let pix = dcmPixList?.object(at: maxVal) {
                                                            objcObject(pix, DCMPix.self).convertX(self.horos_mouseXPos, pixY: self.horos_mouseYPos, toDICOMCoords: locationPointer, pixelCenter: true)
                                                        }
                                                    } else {
                                                        self.curDCM?.convertX(self.horos_mouseXPos, pixY: self.horos_mouseYPos, toDICOMCoords: locationPointer, pixelCenter: true)
                                                    }
                                                }
                                            }

                                            if self.curDCM?.is3DPlane() ?? false {
                                                if fabs(Double(location.0)) < 1.0 && location.0 != 0.0 && (self.curDCM?.pixelSpacingX ?? 0) < 0.2 {
                                                    tempString.appendFormat("X: %2.2f %cm Y: %2.2f %cm Z: %2.2f %cm" as NSString, Double(location.0) * 1000.0, Int32(0xB5), Double(location.1) * 1000.0, Int32(0xB5), Double(location.2) * 1000.0, Int32(0xB5))
                                                } else {
                                                    tempString.appendFormat("X: %2.2f mm Y: %2.2f mm Z: %2.2f mm" as NSString, Double(location.0), Double(location.1), Double(location.2))
                                                }
                                            } else {
                                                if fabs(Double(location.0)) < 1.0 && location.0 != 0.0 && (self.curDCM?.pixelSpacingX ?? 0) < 0.2 {
                                                    tempString.appendFormat("X: %2.2f %cm Y: %2.2f %cm" as NSString, Double(location.0) * 1000.0, Int32(0xB5), Double(location.1) * 1000.0, Int32(0xB5))
                                                } else {
                                                    tempString.appendFormat("X: %2.2f mm Y: %2.2f mm" as NSString, Double(location.0), Double(location.1))
                                                }
                                            }
                                        }
                                    }
                                } else if item.isEqual(to: "Window Level / Window Width") {
                                    let lwl: Float = self.curDCM?.wl ?? 0
                                    let lww: Float = self.curDCM?.ww ?? 0

                                    let iwl = cInt32(Double(lwl))
                                    let iww = cInt32(Double(lww))

                                    if lww < 50 && (lwl != Float(iwl) || lww != Float(iww)) {
                                        tempString.appendFormat(NSLocalizedString("WL: %0.4f WW: %0.4f", comment: "WW: window width, WL: window level") as NSString, Double(lwl), Double(lww))
                                    } else {
                                        tempString.appendFormat(NSLocalizedString("WL: %d WW: %d", comment: "WW: window width, WL: window level") as NSString, cInt32(Double(lwl)), cInt32(Double(lww)))
                                    }

                                    let curImage = Int(self.horos_curImage)
                                    if objcIsEqualToString(objcObject(self.horos_dcmFilesList?.object(at: curImage))?.value(forKey: "modality"), "PT") || (UserDefaults.standard.bool(forKey: "mouseWindowingNM") && objcIsEqualToString(objcObject(self.horos_dcmFilesList?.object(at: curImage))?.value(forKey: "modality"), "NM")) {
                                        if (self.curDCM?.maxValueOfSeries ?? 0) != 0 {
                                            let min = lwl - lww / 2, max = lwl + lww / 2

                                            // %d with long arguments, as the Objective-C passed them.
                                            tempString2.appendFormat(NSLocalizedString("From: %d %% (%0.2f) to: %d %% (%0.2f)", comment: "No special characters for this string, only ASCII characters.") as NSString, cLong(Double(min) * 100.0 / Double(self.curDCM?.maxValueOfSeries ?? 0)), Double(lwl - lww / 2), cLong(Double(max) * 100.0 / Double(self.curDCM?.maxValueOfSeries ?? 0)), Double(lwl + lww / 2))
                                        }
                                    }
                                } else if item.isEqual(to: "Plugin") {

                                    let userInfo = NSDictionary(objects: [NSNumber(value: Float(yRaster)),
                                                                          NSNumber(value: Float(xRaster)),
                                                                          NSNumber(value: intValue(align, key))],
                                                                forKeys: ["yRaster" as NSString, "xRaster" as NSString, "alignment" as NSString])


                                    NotificationCenter.default.post(name: .OsirixDrawTextInfo,
                                                                    object: self,
                                                                    userInfo: userInfo as? [AnyHashable: Any])
                                    yRaster += Int(increment)
                                } else if item.isEqual(to: "Orientation") {
                                    if !orientationDrawn { self.drawOrientation(size) }
                                    orientationDrawn = true
                                } else if item.isEqual(to: "Thickness / Location / Position") {
                                    if (self.curDCM?.sliceThickness ?? 0) != 0 && (self.curDCM?.sliceLocation ?? 0) != 0 {
                                        if (self.curDCM?.stack ?? 0) > 1 {
                                            var vv: Float = 0, pp: Float = 0

                                            self.getThickSlabThickness(&vv, location: &pp)

                                            if vv < 1.0 && vv != 0.0 {
                                                if fabs(Double(pp)) < 1.0 && pp != 0.0 {
                                                    tempString.appendFormat(NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f %cm", comment: "") as NSString, fabs(Double(vv) * 1000.0), Int32(0xB5), Double(pp) * 1000.0, Int32(0xB5))
                                                } else {
                                                    tempString.appendFormat(NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f mm", comment: "") as NSString, fabs(Double(vv) * 1000.0), Int32(0xB5), Double(pp))
                                                }
                                            } else {
                                                tempString.appendFormat(NSLocalizedString("Thickness: %0.2f mm Location: %0.2f mm", comment: "") as NSString, fabs(Double(vv)), Double(pp))
                                            }
                                        } else if fullText {
                                            if (self.curDCM?.sliceThickness ?? 0) < 1.0 && (self.curDCM?.sliceThickness ?? 0) != 0.0 {
                                                if fabs(self.curDCM?.sliceLocation ?? 0) < 1.0 && (self.curDCM?.sliceLocation ?? 0) != 0.0 {
                                                    tempString.appendFormat(NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f %cm", comment: "") as NSString, (self.curDCM?.sliceThickness ?? 0) * 1000.0, Int32(0xB5), (self.curDCM?.sliceLocation ?? 0) * 1000.0, Int32(0xB5))
                                                } else {
                                                    tempString.appendFormat(NSLocalizedString("Thickness: %0.2f %cm Location: %0.2f mm", comment: "") as NSString, (self.curDCM?.sliceThickness ?? 0) * 1000.0, Int32(0xB5), self.curDCM?.sliceLocation ?? 0)
                                                }
                                            } else {
                                                tempString.appendFormat(NSLocalizedString("Thickness: %0.2f mm Location: %0.2f mm", comment: "") as NSString, self.curDCM?.sliceThickness ?? 0, self.curDCM?.sliceLocation ?? 0)
                                            }
                                        }
                                    } else if objcProperty(self.curDCM, kViewPositionGetter) != nil || objcProperty(self.curDCM, kPatientPositionGetter) != nil {
                                        if let viewPosition = objcProperty(self.curDCM, kViewPositionGetter) {
                                            tempString.appendFormat(NSLocalizedString("Position: %@ ", comment: "") as NSString, arg(viewPosition))
                                        }
                                        if let patientPosition = objcProperty(self.curDCM, kPatientPositionGetter) {
                                            if objcProperty(self.curDCM, kViewPositionGetter) != nil {
                                                tempString.append(objcObject(patientPosition, NSString.self) as String)
                                            } else {
                                                tempString.appendFormat(NSLocalizedString("Position: %@ ", comment: "") as NSString, arg(patientPosition))
                                            }
                                        }
                                    }
                                } else if item.isEqual(to: "PatientName") {
                                    let curImage = Int(self.horos_curImage)
                                    let dcmFilesList = self.horos_dcmFilesList
                                    if Int32(annotFull) == self.horos_annotationType && curImage >= 0 && curImage < (dcmFilesList?.count ?? 0) {
                                        let patientName = objcObject(dcmFilesList?.object(at: curImage))?.value(forKeyPath: "series.study.name")
                                        if let patientName = patientName.map({ objcObject($0, NSString.self) }), patientName.length != 0 {
                                            tempString.append(patientName as String)
                                        }
                                    }
                                } else if fullText {
                                    tempString.appendFormat(" %@" as NSString, arg(item))
                                }
                                j += 1
                            }

                            tempString.setString(tempString.trimmingCharacters(in: .whitespaces))
                            tempString2.setString(tempString2.trimmingCharacters(in: .whitespaces))
                            tempString3.setString(tempString3.trimmingCharacters(in: .whitespaces))
                            tempString4.setString(tempString4.trimmingCharacters(in: .whitespaces))

                            if !tempString.isEqual(to: "") {
                                var xAdd = 0
                                if key.isEqual(to: "TopLeft") && Float(yRaster &- Int(increment)) < Float(colorBoxSize) + 2 * sf {
                                    xAdd = Int(colorBoxSize)
                                }

                                self.drawNSStringGL(tempString as String, fontList, xRaster &+ xAdd, yRaster, align: DCMViewTextAlign(rawValue: UInt32(bitPattern: intValue(align, key))), useStringTexture: useStringTexture)
                                yRaster += Int(increment)
                            }
                            if !tempString2.isEqual(to: "") {
                                var xAdd = 0
                                if key.isEqual(to: "TopLeft") && Float(yRaster &- Int(increment)) < Float(colorBoxSize) + 2 * sf {
                                    xAdd = Int(colorBoxSize)
                                }

                                self.drawNSStringGL(tempString2 as String, fontList, xRaster &+ xAdd, yRaster, align: DCMViewTextAlign(rawValue: UInt32(bitPattern: intValue(align, key))), useStringTexture: useStringTexture)
                                yRaster += Int(increment)
                            }
                            if !tempString3.isEqual(to: "") {
                                var xAdd = 0
                                if key.isEqual(to: "TopLeft") && Float(yRaster &- Int(increment)) < Float(colorBoxSize) + 2 * sf {
                                    xAdd = Int(colorBoxSize)
                                }

                                self.drawNSStringGL(tempString3 as String, fontList, xRaster &+ xAdd, yRaster, align: DCMViewTextAlign(rawValue: UInt32(bitPattern: intValue(align, key))), useStringTexture: useStringTexture)
                                yRaster += Int(increment)
                            }
                            if !tempString4.isEqual(to: "") {
                                var xAdd = 0
                                if key.isEqual(to: "TopLeft") && Float(yRaster &- Int(increment)) < Float(colorBoxSize) + 2 * sf {
                                    xAdd = Int(colorBoxSize)
                                }

                                self.drawNSStringGL(tempString4 as String, fontList, xRaster &+ xAdd, yRaster, align: DCMViewTextAlign(rawValue: UInt32(bitPattern: intValue(align, key))), useStringTexture: useStringTexture)
                                yRaster += Int(increment)
                            }
                        }
                    } catch {
                        if self.horos_exceptionDisplayed == false {
                            let e = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
                            HorosAlertPanel.runCritical(title: NSLocalizedString("Annotations Error", comment: ""), message: String(format: "%@\r\r%@", arg(e), arg(annot)), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)

                            NSLog("draw custom annotation exception: %@\r\r%@", arg(e), arg(annot))

                            self.horos_exceptionDisplayed = true
                        }
                    }
                } // while
                k += 1
            } // for k

            yRaster = cLong(Double(size.origin.y + size.size.height - 2))
            xRaster = cLong(Double(size.origin.x + size.size.width - 2))
            if fullText {
                self.drawNSStringGL("Made In IsiX DICOM Viewer", fontList, xRaster, yRaster, rightAlignment: true, useStringTexture: true)
            }
        }
    }

    @objc(drawTextualData::)
    public dynamic func drawTextualData(_ size: NSRect, _ annotations: Int) {
        self.drawTextualData(size, annotationsLevel: annotations, fullText: true, onlyOrientation: false)
    }
}
