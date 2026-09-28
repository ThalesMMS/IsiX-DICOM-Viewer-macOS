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

/// (long)v of the former C: truncation toward zero, saturated, NaN as 0.
private func cLong(_ v: Float) -> Int {
    if v.isNaN { return 0 }
    if v >= 9223372036854775808.0 { return .max }
    if v < -9223372036854775808.0 { return .min }
    return Int(v)
}

/// (unsigned int)v of the former C: truncation toward zero, saturated, NaN as 0.
private func cUInt32(_ v: Float) -> UInt32 {
    if v.isNaN || v <= 0 { return 0 }
    if v >= 4294967296.0 { return .max }
    return UInt32(v)
}

/// [array addObject:object]: a nil object raises NSInvalidArgumentException,
/// as it did; nothing for a nil array, as a message to nil.
private func addObject(_ object: Any?, to array: NSMutableArray?) {
    guard let array = array else { return }
    if let object = object {
        array.add(object)
    } else {
        _ = array.perform(#selector(NSMutableArray.add(_:)), with: nil)
    }
}

/// Manages 3D flythrus: the cameras the user chose (the steps) and the path
/// interpolated between them.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/FlyThru.h> are those of the former class. Spline3D and Piecewise3D
/// come from FlyThruHostBridge, because their headers are C++. FlyThru.xib
/// binds flyThru.stepCameras, the steps' array, which the steps array
/// controller changes in place through the indexed accessors below.
@objc(FlyThru)
public final class FlyThru: NSObject {
    /// The former stepCameras ivar, behind the steps property.
    private var stepCamerasStorage: NSMutableArray?
    private var pathCamerasStorage: NSMutableArray?
    private var stepsPositionInPathStorage: NSMutableArray?

    @objc public dynamic var steps: NSMutableArray? {
        get { return stepCamerasStorage }
        set { stepCamerasStorage = newValue }
    }

    @objc public dynamic var pathCameras: NSMutableArray? {
        get { return pathCamerasStorage }
        set { pathCamerasStorage = newValue }
    }

    @objc public dynamic var stepsPositionInPath: NSMutableArray? {
        get { return stepsPositionInPathStorage }
        set { stepsPositionInPathStorage = newValue }
    }

    @objc public dynamic var numberOfFrames: Int32 = 0
    /// 1: spline / 2: piecewise
    @objc public dynamic var interpolationMethod: Int32 = 0

    @objc public dynamic var constantSpeed: Bool = false
    @objc public dynamic var loop: Bool = false

    // MARK: stepCameras, the key FlyThru.xib binds

    /// The steps' array itself, as KVC read the ivar.
    @objc public var stepCameras: NSMutableArray? {
        return stepCamerasStorage
    }

    @objc(insertObject:inStepCamerasAtIndex:)
    public func insertObject(_ object: Any, inStepCamerasAt index: Int) {
        stepCamerasStorage?.insert(object, at: index)
    }

    @objc(insertStepCameras:atIndexes:)
    public func insertStepCameras(_ objects: [Any], at indexes: IndexSet) {
        stepCamerasStorage?.insert(objects, at: indexes)
    }

    @objc(removeObjectFromStepCamerasAtIndex:)
    public func removeObjectFromStepCameras(at index: Int) {
        stepCamerasStorage?.removeObject(at: index)
    }

    @objc(removeStepCamerasAtIndexes:)
    public func removeStepCameras(at indexes: IndexSet) {
        stepCamerasStorage?.removeObjects(at: indexes)
    }

    @objc(replaceObjectInStepCamerasAtIndex:withObject:)
    public func replaceObjectInStepCameras(at index: Int, with object: Any) {
        stepCamerasStorage?.replaceObject(at: index, with: object)
    }

    // MARK: -

    @objc public override convenience init() {
        self.init(firstCamera: nil)
    }

    // steps
    @objc(initWithFirstCamera:)
    public init(firstCamera sCamera: Camera?) {
        NSLog("FlyThru:initWithFirstCamera")
        stepCamerasStorage = NSMutableArray(capacity: 0)
        pathCamerasStorage = NSMutableArray(capacity: 0)
        stepsPositionInPathStorage = nil
        super.init()

        if let sCamera = sCamera { self.addCamera(sCamera) }
        self.numberOfFrames = 50
        self.interpolationMethod = 1
        self.constantSpeed = true
        self.loop = false
    }

    @objc(addCamera:)
    public func addCamera(_ aCamera: Camera?) {
        addObject(aCamera, to: stepCamerasStorage)
    }

    @objc(addCamera:atIndex:)
    public func addCamera(_ aCamera: Camera?, atIndex index: Int32) {
        guard let stepCameras = stepCamerasStorage else { return }
        if let aCamera = aCamera {
            stepCameras.insert(aCamera, at: Int(index))
        } else {
            NSException(name: .invalidArgumentException, reason: "-[FlyThru addCamera:atIndex:]: object cannot be nil", userInfo: nil).raise()
        }
    }

    @objc(removeCameraAtIndex:)
    public func removeCamera(atIndex index: Int32) {
        if index >= 0 {
            stepCamerasStorage?.removeObject(at: Int(index))
        }
    }

    @objc public func removeAllCamera() {
        stepCamerasStorage?.removeAllObjects()
    }

    /// Point3D (value, 0, 0): a scalar made a 3D point, to interpolate it with
    /// the same -path:::.
    private static func scalar(_ value: Float) -> Point3D {
        return Point3D(values: value, 0, 0)
    }

    @objc public func computePath() {
        let tempStepCameras = NSMutableArray(capacity: (stepCamerasStorage?.count ?? 0) + 1)
        tempStepCameras.addObjects(from: (stepCamerasStorage as? [Any]) ?? [])

        if loop {
            addObject(stepCamerasStorage?.object(at: 0), to: tempStepCameras)
            self.numberOfFrames += 1
        }
        NSLog("numberOfFrames: %d", self.numberOfFrames)
        let nbStep = tempStepCameras.count

        // instantiation
        let stepPosition = NSMutableArray(capacity: nbStep)
        let stepViewUp = NSMutableArray(capacity: nbStep)
        let stepFocalPoint = NSMutableArray(capacity: nbStep)
        let stepClippingRangeNear = NSMutableArray(capacity: nbStep)
        let stepClippingRangeFar = NSMutableArray(capacity: nbStep)
        let stepViewAngle = NSMutableArray(capacity: nbStep)
        let stepEyeAngle = NSMutableArray(capacity: nbStep)
        let stepParallelScale = NSMutableArray(capacity: nbStep)
        let stepWL = NSMutableArray(capacity: nbStep)
        let stepWW = NSMutableArray(capacity: nbStep)
        let stepCroppingPlanes = NSMutableArray(capacity: nbStep)
        let stepFusionPercentage = NSMutableArray(capacity: nbStep)
        let stepMovieIndexIn4D = NSMutableArray(capacity: nbStep)

        // initialisation
        var envelopeLevelMin: Float = 0, envelopeLevelMax: Float = 0, envelopeWidthMin: Float = 0, envelopeWidthMax: Float = 0
        var haveWindowEnvelope = false
        for case let cam as Camera in tempStepCameras {
            addObject(cam.position, to: stepPosition)
            addObject(cam.viewUp, to: stepViewUp)
            addObject(cam.focalPoint, to: stepFocalPoint)
            // for scalar values : creating artificial 3D points to be able to use the same method 'path'
            stepClippingRangeNear.add(FlyThru.scalar(cam.clippingRangeNear))
            stepClippingRangeFar.add(FlyThru.scalar(cam.clippingRangeFar))
            stepViewAngle.add(FlyThru.scalar(cam.viewAngle))
            stepEyeAngle.add(FlyThru.scalar(cam.eyeAngle))
            stepParallelScale.add(FlyThru.scalar(cam.parallelScale))
            stepWL.add(FlyThru.scalar(cam.wl))
            stepWW.add(FlyThru.scalar(cam.ww))
            stepFusionPercentage.add(FlyThru.scalar(cam.fusionPercentage))
            stepMovieIndexIn4D.add(FlyThru.scalar(Float(cam.movieIndexIn4D)))

            addObject(cam.croppingPlanes, to: stepCroppingPlanes)

            if cam.wl.isFinite && cam.ww.isFinite && cam.ww != 0 {
                if !haveWindowEnvelope {
                    envelopeLevelMin = cam.wl; envelopeLevelMax = cam.wl
                    envelopeWidthMin = cam.ww; envelopeWidthMax = cam.ww
                    haveWindowEnvelope = true
                } else {
                    if cam.wl < envelopeLevelMin { envelopeLevelMin = cam.wl }
                    if cam.wl > envelopeLevelMax { envelopeLevelMax = cam.wl }
                    if cam.ww < envelopeWidthMin { envelopeWidthMin = cam.ww }
                    if cam.ww > envelopeWidthMax { envelopeWidthMax = cam.ww }
                }
            }
        }

        // interpolation
        stepsPositionInPathStorage = NSMutableArray(capacity: 0)

        let pathPosition = self.path(stepPosition, interpolationMethod, true)
        let pathViewUp = self.path(stepViewUp, interpolationMethod, false)
        let pathFocalPoint = self.path(stepFocalPoint, interpolationMethod, false)
        let pathClippingRangeNear = self.path(stepClippingRangeNear, interpolationMethod, false)
        let pathClippingRangeFar = self.path(stepClippingRangeFar, interpolationMethod, false)
        let pathViewAngle = self.path(stepViewAngle, interpolationMethod, false)
        let pathEyeAngle = self.path(stepEyeAngle, interpolationMethod, false)
        let pathParallelScale = self.path(stepParallelScale, interpolationMethod, false)
        let pathWL = self.path(stepWL, interpolationMethod, false)
        let pathWW = self.path(stepWW, interpolationMethod, false)

        let pathCroppingPlanes = self.pathCroppingPlanes(stepCroppingPlanes, interpolationMethod, false)

        let pathFusionPercentage = self.path(stepFusionPercentage, interpolationMethod, false)
        let pathMovieIndexIn4D = self.path(stepMovieIndexIn4D, interpolationMethod, false)

        // result
        let ePathViewUp = pathViewUp.objectEnumerator()
        let ePathFocalPoint = pathFocalPoint.objectEnumerator()
        let ePathClippingRangeNear = pathClippingRangeNear.objectEnumerator()
        let ePathClippingRangeFar = pathClippingRangeFar.objectEnumerator()
        let ePathViewAngle = pathViewAngle.objectEnumerator()
        let ePathEyeAngle = pathEyeAngle.objectEnumerator()
        let ePathParallelScale = pathParallelScale.objectEnumerator()
        let ePathWL = pathWL.objectEnumerator()
        let ePathWW = pathWW.objectEnumerator()
        let ePathCroppingPlanes = pathCroppingPlanes.objectEnumerator()
        let ePathFusionPercentage = pathFusionPercentage.objectEnumerator()
        let ePathMovieIndexIn4D = pathMovieIndexIn4D.objectEnumerator()

        /// [p x] of the next Point3D: 0 past the end, as a message to nil.
        func nextX(_ e: NSEnumerator) -> Float {
            return (e.nextObject() as? Point3D)?.x ?? 0
        }

        pathCamerasStorage?.removeAllObjects()

        for pos in pathPosition {
            let vUp = ePathViewUp.nextObject() as? Point3D
            let foPt = ePathFocalPoint.nextObject() as? Point3D
            let near = nextX(ePathClippingRangeNear)
            let far = nextX(ePathClippingRangeFar)
            let view = nextX(ePathViewAngle)
            let eye = nextX(ePathEyeAngle)
            let para = nextX(ePathParallelScale)
            let iwl = nextX(ePathWL)
            let iww = nextX(ePathWW)
            let cropp = ePathCroppingPlanes.nextObject() as? NSMutableArray
            let fusion = nextX(ePathFusionPercentage)
            let index4D = nextX(ePathMovieIndexIn4D)

            let c: Camera = Camera()
            c.position = pos as? Point3D
            c.viewUp = vUp
            c.focalPoint = foPt
            c.setClippingRangeFrom(near, to: far)
            c.viewAngle = view
            c.eyeAngle = eye
            c.parallelScale = para
            var interpolatedLevel = iwl
            var interpolatedWidth = iww
            if haveWindowEnvelope {
                interpolatedLevel = Float(FlyThruWindow.clampedLevel(Double(interpolatedLevel), rangeMin: Double(envelopeLevelMin), rangeMax: Double(envelopeLevelMax)))
                interpolatedWidth = Float(FlyThruWindow.clampedWidth(Double(interpolatedWidth), rangeMin: Double(envelopeWidthMin), rangeMax: Double(envelopeWidthMax)))
            }
            c.setWLWW(interpolatedLevel, interpolatedWidth)
            c.croppingPlanes = cropp
            c.fusionPercentage = fusion
            c.movieIndexIn4D = cLong(index4D)

            pathCamerasStorage?.add(c)
        }

        if loop {
            pathCamerasStorage?.removeLastObject() // otherwise this frame appears 2 times (it is the first AND last frame)
        }

        self.numberOfFrames = Int32(truncatingIfNeeded: pathCamerasStorage?.count ?? 0)
    }

    @objc(pathCroppingPlanes:::)
    public func pathCroppingPlanes(_ planesSteps: NSMutableArray?, _ interpolMeth: Int32, _ computeStepsPositions: Bool) -> NSMutableArray {
        let origins = (0 ..< 6).map { _ in NSMutableArray() }
        let vectors = (0 ..< 6).map { _ in NSMutableArray() }

        for case let planes as NSArray in planesSteps ?? NSMutableArray() {
            var i = 0
            for case let v as NSValue in planes {
                // A camera has 6 planes; the former C arrays had no room for more.
                guard i < 6 else { break }
                let plane = v.n3PlaneValue()

                let origin: Point3D = Point3D(values: Float(plane.point.x), Float(plane.point.y), Float(plane.point.z))
                let vector: Point3D = Point3D(values: Float(plane.normal.x), Float(plane.normal.y), Float(plane.normal.z))
                origins[i].add(origin)
                vectors[i].add(vector)

                i += 1
            }
        }

        let path = NSMutableArray(capacity: planesSteps?.count ?? 0)

        let o = NSMutableArray()
        let n = NSMutableArray()

        for i in 0 ..< 6 {
            o.add(self.path(origins[i], interpolMeth, computeStepsPositions))
            n.add(self.path(vectors[i], interpolMeth, computeStepsPositions))
        }

        let steps = Int32(truncatingIfNeeded: (o.lastObject as? NSArray)?.count ?? 0)

        for x in 0 ..< Int(max(steps, 0)) {
            let croppingPlanes = NSMutableArray()

            for i in 0 ..< 6 {
                let origin = ((o.object(at: i) as! NSArray).object(at: x) as! Point3D).n3VectorValue()
                let normal = ((n.object(at: i) as! NSArray).object(at: x) as! Point3D).n3VectorValue()
                let plane = N3PlaneMake(origin, N3VectorNormalize(normal))

                let value: NSValue = NSValue(n3Plane: plane)
                croppingPlanes.add(value)
            }

            path.add(croppingPlanes)
        }

        return path
    }

    @objc(path:::)
    public func path(_ pts: NSMutableArray?, _ interpolMeth: Int32, _ computeStepsPositions: Bool) -> NSMutableArray {
        let function = FlyThruHostBridge.interpolation(withMethod: interpolMeth)

        let nbStep = pts?.count ?? 0
        var t: Float
        var deltaT: Float
        t = 0
        deltaT = Float(1.0 / Double(Float(nbStep - 1)))

        for stepPoint in pts ?? NSMutableArray() {
            let p = Point3D(point3D: stepPoint as? Point3D)
            function?.addPoint(t, p)

            t = t + deltaT
        }

        let path = NSMutableArray(capacity: nbStep)
        deltaT = Float(1.0 / Double(Float(numberOfFrames - 1)))

        if computeStepsPositions {
            let inc = Float(numberOfFrames) / Float(nbStep - 1)
            t = 0
            while t <= Float(numberOfFrames) {
                stepsPositionInPathStorage?.add(NSNumber(value: cUInt32(t)))
                t += inc
            }
        }

        t = 0
        while t <= 1 {
            let tempPoint = function?.evaluate(at: t)
            addObject(tempPoint, to: path)
            t += deltaT
        }

        return path
    }

    @objc public func exportToXML() -> NSMutableDictionary {
        let xml = NSMutableDictionary()
        let temp = NSMutableArray()

        for case let cam as Camera in stepCamerasStorage ?? NSMutableArray() {
            addObject(cam.exportToXML(), to: temp)
        }

        xml.setObject(temp, forKey: "Step Cameras" as NSString)
        return xml
    }

    @objc(setFromDictionary:)
    public func setFromDictionary(_ xml: NSDictionary?) {
        self.removeAllCamera()
        let stepsXML = xml?.value(forKey: "Step Cameras")
        for cam in (stepsXML as? NSArray) ?? NSArray() {
            self.addCamera(Camera(dictionary: cam as? [AnyHashable: Any]))
        }
    }
}
