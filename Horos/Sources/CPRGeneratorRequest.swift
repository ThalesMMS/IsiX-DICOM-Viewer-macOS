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

/// A double converted to NSUInteger as arm64 does it (fcvtzu): NaN and negative
/// values give 0, values past the top give the largest value.
private func unsignedTruncating(_ value: CGFloat) -> UInt {
    if value.isNaN || value < 1 {
        return 0
    }
    if value >= 18446744073709551616.0 {
        return UInt.max
    }
    return UInt(value)
}

// a class to encapsulate all the different parameters required to generate a CPR Image
// still working on how to engineer this, it this version sticks, this will be broken up into two files

/// Implemented in Swift, with its three subclasses: the Objective-C
/// names, the selectors and <Horos/CPRGeneratorRequest.h> are those of the
/// former classes. Open, because the three requests subclass it.
@objc(CPRGeneratorRequest)
open class CPRGeneratorRequest: NSObject, NSCopying {
    // specifify the size of the returned data
    @objc public dynamic var pixelsWide: UInt = 0
    @objc public dynamic var pixelsHigh: UInt = 0

    @objc public dynamic var slabWidth: CGFloat = 0 // width of the slab in millimeters
    @objc public dynamic var slabSampleDistance: CGFloat = 0 // mm/slab if this is set to 0, a reasonable value will be picked automatically, otherwise, this value
    @objc public dynamic var interpolationMode: CPRInterpolationMode = 0

    @objc public dynamic var context: UnsafeMutableRawPointer?

    /// -copyWithZone: makes the copy with -init of the receiver's class.
    @objc public required override init() {
        super.init()
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = type(of: self).init()
        copy.pixelsWide = pixelsWide
        copy.pixelsHigh = pixelsHigh
        copy.slabWidth = slabWidth
        copy.slabSampleDistance = slabSampleDistance
        copy.interpolationMode = interpolationMode
        copy.context = context

        return copy
    }

    open override func isEqual(_ object: Any?) -> Bool {
        if let generatorRequest = object as? CPRGeneratorRequest {
            if pixelsWide == generatorRequest.pixelsWide &&
                pixelsHigh == generatorRequest.pixelsHigh &&
                slabWidth == generatorRequest.slabWidth &&
                slabSampleDistance == generatorRequest.slabSampleDistance &&
                interpolationMode == generatorRequest.interpolationMode &&
                context == generatorRequest.context {
                return true
            }
        }
        return false
    }

    /// The bits of the two CGFloats and of the interpolation mode, as the former
    /// code read them through NSUInteger pointers.
    open override var hash: Int {
        let hash = pixelsWide ^ pixelsHigh ^ slabWidth.bitPattern ^ slabSampleDistance.bitPattern ^ UInt(bitPattern: interpolationMode) ^ UInt(bitPattern: context)
        return Int(bitPattern: hash)
    }

    @objc open func operationClass() -> AnyClass? {
        return nil
    }
}

@objc(CPRStraightenedGeneratorRequest)
public final class CPRStraightenedGeneratorRequest: CPRGeneratorRequest {
    @objc public dynamic var bezierPath: N3BezierPath?
    @objc public dynamic var initialNormal = N3Vector() // the down direction on the left/top of the output CPR, this vector must be normal to the initial tangent of the curve

    @objc public dynamic var projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)
    // @property (nonatomic, readwrite, assign) BOOL vertical; // the straightened bezier is horizantal across the screen, or vertical it would be cool to implement this one day

    @objc public required init() {
        super.init()
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! CPRStraightenedGeneratorRequest
        copy.bezierPath = bezierPath
        copy.initialNormal = initialNormal
        copy.projectionMode = projectionMode
        //    copy.vertical = _vertical;
        return copy
    }

    public override func isEqual(_ object: Any?) -> Bool {
        if let straightenedGeneratorRequest = object as? CPRStraightenedGeneratorRequest {
            if super.isEqual(object) &&
                bezierPath?.isEqual(to: straightenedGeneratorRequest.bezierPath) ?? false &&
                N3VectorEqualToVector(initialNormal, straightenedGeneratorRequest.initialNormal) &&
                projectionMode == straightenedGeneratorRequest.projectionMode /*&&*/
                /* _vertical == straightenedGeneratorRequest.vertical */ {
                return true
            }
        }
        return false
    }

    public override var hash: Int { // a not that great hash function....
        let hash = UInt(bitPattern: super.hash) ^ UInt(bitPattern: bezierPath?.hash ?? 0) ^ unsignedTruncating(N3VectorLength(initialNormal)) ^ UInt(bitPattern: projectionMode) /* ^ (NSUInteger)_vertical */
        return Int(bitPattern: hash)
    }

    @objc public override func operationClass() -> AnyClass? {
        return CPRStraightenedOperation.self
    }
}

@objc(CPRStretchedGeneratorRequest)
public final class CPRStretchedGeneratorRequest: CPRGeneratorRequest {
    @objc public dynamic var bezierPath: N3BezierPath?

    @objc public dynamic var projectionNormal = N3Vector()
    @objc public dynamic var midHeightPoint = N3Vector() // this point in the volume will be half way up the volume

    @objc public dynamic var projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)

    @objc public required init() {
        super.init()
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! CPRStretchedGeneratorRequest
        copy.bezierPath = bezierPath
        copy.projectionNormal = projectionNormal
        copy.midHeightPoint = midHeightPoint
        copy.projectionMode = projectionMode
        //    copy.vertical = _vertical;
        return copy
    }

    public override func isEqual(_ object: Any?) -> Bool {
        if let stretchedGeneratorRequest = object as? CPRStretchedGeneratorRequest {
            if super.isEqual(object) &&
                bezierPath?.isEqual(to: stretchedGeneratorRequest.bezierPath) ?? false &&
                N3VectorEqualToVector(projectionNormal, stretchedGeneratorRequest.projectionNormal) &&
                N3VectorEqualToVector(midHeightPoint, stretchedGeneratorRequest.midHeightPoint) &&
                projectionMode == stretchedGeneratorRequest.projectionMode {
                return true
            }
        }
        return false
    }

    public override var hash: Int { // a not that great hash function....
        let hash = UInt(bitPattern: super.hash) ^ UInt(bitPattern: bezierPath?.hash ?? 0) ^ unsignedTruncating(N3VectorLength(projectionNormal)) ^
            unsignedTruncating(N3VectorLength(midHeightPoint)) ^ UInt(bitPattern: projectionMode)
        return Int(bitPattern: hash)
    }

    @objc public override func operationClass() -> AnyClass? {
        return CPRStretchedOperation.self
    }
}

@objc(CPRObliqueSliceGeneratorRequest)
public final class CPRObliqueSliceGeneratorRequest: CPRGeneratorRequest {
    // Stored apart from the properties: the former setters normalize the
    // directions, and the (DCMPixAndVolume) accessors and
    // -setSliceToDicomTransform: wrote the ivars without KVO notifications.
    private var _origin = N3Vector()
    private var _directionX = N3Vector()
    private var _directionY = N3Vector()

    private var _pixelSpacingX: CGFloat = 0
    private var _pixelSpacingY: CGFloat = 0

    @objc public dynamic var projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)

    public override class func keyPathsForValuesAffectingValue(forKey key: String) -> Set<String> {
        let keyPaths = super.keyPathsForValuesAffectingValue(forKey: key)

        if key == "origin" ||
            key == "directionX" ||
            key == "directionY" ||
            key == "pixelSpacingX" ||
            key == "pixelSpacingY" {
            return keyPaths.union(["sliceToDicomTransform"])
        } else if key == "sliceToDicomTransform" {
            return keyPaths.union(["origin", "directionX", "directionY", "pixelSpacingX", "pixelSpacingY"])
        } else {
            return keyPaths
        }
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! CPRObliqueSliceGeneratorRequest
        copy.origin = _origin
        copy.directionX = _directionX
        copy.directionY = _directionY
        copy.pixelSpacingX = _pixelSpacingX
        copy.pixelSpacingY = _pixelSpacingY
        copy.projectionMode = projectionMode
        return copy
    }

    @objc public required init() {
        super.init()
    }

    /// The length of the vectors will be considered to be the pixel spacing.
    @objc(initWithCenter:pixelsWide:pixelsHigh:xBasis:yBasis:)
    public init(center: N3Vector, pixelsWide: UInt, pixelsHigh: UInt, xBasis: N3Vector, yBasis: N3Vector) {
        super.init()
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh

        _directionX = N3VectorNormalize(xBasis)
        _pixelSpacingX = N3VectorLength(xBasis)
        _directionY = N3VectorNormalize(yBasis)
        _pixelSpacingY = N3VectorLength(yBasis)
        _origin = N3VectorAdd(N3VectorAdd(center, N3VectorScalarMultiply(xBasis, CGFloat(pixelsWide) / -2.0)), N3VectorScalarMultiply(yBasis, CGFloat(pixelsHigh) / -2.0))

        projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)
    }

    public override func isEqual(_ object: Any?) -> Bool {
        if let obliqueSliceGeneratorRequest = object as? CPRObliqueSliceGeneratorRequest {
            if super.isEqual(object) &&
                N3VectorEqualToVector(_origin, obliqueSliceGeneratorRequest.origin) &&
                N3VectorEqualToVector(_directionX, obliqueSliceGeneratorRequest.directionX) &&
                N3VectorEqualToVector(_directionY, obliqueSliceGeneratorRequest.directionY) &&
                _pixelSpacingX == obliqueSliceGeneratorRequest.pixelSpacingX &&
                _pixelSpacingY == obliqueSliceGeneratorRequest.pixelSpacingY &&
                projectionMode == obliqueSliceGeneratorRequest.projectionMode {
                return true
            }
        }
        return false
    }

    // No -hash of its own, as before: CPRGeneratorRequest's.

    @objc public override func operationClass() -> AnyClass? {
        return CPRObliqueSliceOperation.self
    }

    @objc public dynamic var origin: N3Vector {
        get { return _origin }
        set { _origin = newValue }
    }

    @objc public dynamic var directionX: N3Vector {
        get { return _directionX }
        set { _directionX = N3VectorNormalize(newValue) }
    }

    @objc public dynamic var directionY: N3Vector {
        get { return _directionY }
        set { _directionY = N3VectorNormalize(newValue) }
    }

    @objc public dynamic var pixelSpacingX: CGFloat { // mm/pixel
        get { return _pixelSpacingX }
        set { _pixelSpacingX = newValue }
    }

    @objc public dynamic var pixelSpacingY: CGFloat {
        get { return _pixelSpacingY }
        set { _pixelSpacingY = newValue }
    }

    @objc public dynamic var sliceToDicomTransform: N3AffineTransform {
        get {
            let crossVector = N3VectorNormalize(N3VectorCrossProduct(_directionX, _directionY))
            let pixelSpacingZ: CGFloat = 1.0 // totally bogus, but there is no right value, and this should give something that is reasonable

            var sliceToDicomTransform = N3AffineTransformIdentity

            sliceToDicomTransform.m11 = _directionX.x * _pixelSpacingX
            sliceToDicomTransform.m12 = _directionX.y * _pixelSpacingX
            sliceToDicomTransform.m13 = _directionX.z * _pixelSpacingX

            sliceToDicomTransform.m21 = _directionY.x * _pixelSpacingY
            sliceToDicomTransform.m22 = _directionY.y * _pixelSpacingY
            sliceToDicomTransform.m23 = _directionY.z * _pixelSpacingY

            sliceToDicomTransform.m31 = crossVector.x * pixelSpacingZ
            sliceToDicomTransform.m32 = crossVector.y * pixelSpacingZ
            sliceToDicomTransform.m33 = crossVector.z * pixelSpacingZ

            sliceToDicomTransform.m41 = _origin.x
            sliceToDicomTransform.m42 = _origin.y
            sliceToDicomTransform.m43 = _origin.z

            return sliceToDicomTransform
        }
        set {
            _directionX = N3VectorMake(newValue.m11, newValue.m12, newValue.m13)
            _pixelSpacingX = N3VectorLength(_directionX)
            _directionX = N3VectorNormalize(_directionX)

            _directionY = N3VectorMake(newValue.m21, newValue.m22, newValue.m23)
            _pixelSpacingY = N3VectorLength(_directionY)
            _directionY = N3VectorNormalize(_directionY)

            _origin = N3VectorMake(newValue.m41, newValue.m42, newValue.m43)
        }
    }

    // MARK: (DCMPixAndVolume), whose KVO code is not yet implemented

    @objc(setOrientation:)
    public func setOrientation(_ orientation: UnsafeMutablePointer<Float>) {
        var doubleOrientation = [Double](repeating: 0, count: 6)

        for i in 0..<6 {
            doubleOrientation[i] = Double(orientation[i])
        }

        setOrientationDouble(&doubleOrientation)
    }

    @objc(setOrientationDouble:)
    public func setOrientationDouble(_ orientation: UnsafeMutablePointer<Double>) {
        _directionX = N3VectorNormalize(N3VectorMake(orientation[0], orientation[1], orientation[2]))
        _directionY = N3VectorNormalize(N3VectorMake(orientation[3], orientation[4], orientation[5]))
    }

    @objc(getOrientation:)
    public func getOrientation(_ orientation: UnsafeMutablePointer<Float>) {
        var doubleOrientation = [Double](repeating: 0, count: 6)

        getOrientationDouble(&doubleOrientation)

        for i in 0..<6 {
            orientation[i] = Float(doubleOrientation[i])
        }
    }

    @objc(getOrientationDouble:)
    public func getOrientationDouble(_ orientation: UnsafeMutablePointer<Double>) {
        orientation[0] = _directionX.x; orientation[1] = _directionX.y; orientation[2] = _directionX.z
        orientation[3] = _directionY.x; orientation[4] = _directionY.y; orientation[5] = _directionY.z
    }

    @objc public var originX: Double {
        get { return _origin.x }
        set { _origin.x = newValue }
    }

    @objc public var originY: Double {
        get { return _origin.y }
        set { _origin.y = newValue }
    }

    @objc public var originZ: Double {
        get { return _origin.z }
        set { _origin.z = newValue }
    }

    @objc public var spacingX: Double {
        get { return _pixelSpacingX }
        set { _pixelSpacingX = newValue }
    }

    @objc public var spacingY: Double {
        get { return _pixelSpacingY }
        set { _pixelSpacingY = newValue }
    }
}
