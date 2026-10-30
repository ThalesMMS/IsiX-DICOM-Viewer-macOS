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
import IsiXROI

// The geometry of a ROI's points and the values it reports: lengths, angles,
// areas, the smoothed outline, the centroid, the pixel values inside it and
// its calcium score. The arithmetic is IsiXROI's; this is what the ROI asks it.
extension ROI {

    // MARK: Points

    /// The points of `array` (MyPoint), as the geometry of IsiXROI takes them.
    static func points(of array: NSArray) -> [CGPoint] {
        let count = array.count
        var result: [CGPoint] = []
        result.reserveCapacity(count)
        var i = 0
        while i < count {
            result.append(point(array, i).point)
            i += 1
        }
        return result
    }

    /// The MyPoint at `index` of an array of a ROI's points, read without a
    /// dynamic cast, which the drawing and the mouse tracking would pay at
    /// every point: these arrays hold MyPoints only (a decoded archive's are
    /// checked as it is read). As -objectAtIndex:, an index out of range
    /// raises NSRangeException.
    @inline(__always)
    static func point(_ array: NSArray, _ index: Int) -> MyPoint {
        Unmanaged<MyPoint>.fromOpaque(CFArrayGetValueAtIndex(array as CFArray, index)!).takeUnretainedValue()
    }

    static func myPoints(_ points: [CGPoint]) -> NSMutableArray {
        let array = NSMutableArray(capacity: points.count)
        for p in points { array.add(MyPoint(point: p)) }
        return array
    }

    func pointsValue() -> NSMutableArray {
        if _type == .t2DPoint {
            return NSMutableArray(object: MyPoint(point: NSPoint(x: _rect.origin.x, y: _rect.origin.y)))
        }
        if _type == .tROI {
            return ROI.myPoints(ROIPlanarGeometry.outline(ofRectangle: _rect))
        }
        if _type == .tOval {
            return ROI.myPoints(ROIPlanarGeometry.outline(ofOval: _rect, resolution: ROI.circleResolution))
        }
        if _type == .tPlain {
            let contour = ITKSegmentation3D.extractContour(mask.buffer, width: Int(mask.width), height: Int(mask.height)) ?? NSMutableArray()
            for case let pt as MyPoint in contour { pt.move(Float(mask.upLeftX), Float(mask.upLeftY)) }
            return contour
        }
        return _points
    }

    /// Doesn't make sense for a rectangle, an oval and a 2D point; nor when locked.
    func setPointsValue(_ pts: NSMutableArray?) {
        if _type == .tROI || _type == .tOval || _type == .t2DPoint { return }
        if _locked { return }
        _points.removeAllObjects()
        var i = 0
        while i < (pts?.count ?? 0) {
            _points.add(pts!.object(at: i))
            i += 1
        }
    }

    @objc(pointAtIndex:)
    @discardableResult
    public func point(at index: UInt) -> NSPoint {
        return (self.points.object(at: Int(index)) as! MyPoint).point
    }

    @objc(setPoint:atIndex:)
    public func setPoint(_ point: NSPoint, at index: UInt) {
        (self.points.object(at: Int(index)) as! MyPoint).point = point
    }

    @objc(addPoint:)
    public func addPoint(_ point: NSPoint) {
        self.points.add(MyPoint(point: point))
    }

    /// The point a label hangs from.
    @discardableResult
    @objc public func lowerRightPoint() -> NSPoint {
        var result = NSPoint.zero
        switch _type {
        case .tMesure:
            let a = _points.object(at: 0) as! MyPoint, b = _points.object(at: 1) as! MyPoint
            result = a.x < b.x ? b.point : a.point
        case .tPlain:
            result = NSPoint(x: CGFloat(mask.downRightX), y: CGFloat(mask.downRightY))
        case .tArrow, .tAngle:
            result = (_points.object(at: 1) as! MyPoint).point
        case .tDynAngle, .tAxis, .tCPolygon, .tOPolygon, .tPencil, .tTAGT:
            let first = _points.object(at: 0) as! MyPoint
            var xmin = first.x, xmax = first.x, ymin = first.y, ymax = first.y
            for case let p as MyPoint in _points {
                if p.x < xmin { xmin = p.x }
                if p.x > xmax { xmax = p.x }
                if p.y < ymin { ymin = p.y }
                if p.y > ymax { ymax = p.y }
            }
            result = NSPoint(x: CGFloat(xmax), y: CGFloat(ymax))
        case .t2DPoint, .tText:
            result = _rect.origin
        case .tOval:
            result = NSPoint(x: _rect.origin.x + _rect.size.width / 4, y: _rect.origin.y + _rect.size.height)
        case .tROI:
            result = NSPoint(x: _rect.origin.x + _rect.size.width, y: _rect.origin.y + _rect.size.height)
        case .tLayerROI:
            result = (_points.object(at: 2) as! MyPoint).point
        default:
            break
        }
        return result
    }

    /// Where the label of a name-only brush hangs: inside its largest piece, in
    /// image pixels. Recomputed when the texture is replaced or recomputed.
    @discardableResult
    @objc public func textureLabelPoint() -> NSPoint {
        guard let buffer = mask.buffer else { return lowerRightPoint() }
        if !hasTextureLabelPoint || textureLabelPointBuffer != buffer {
            if let anchor = BrushLabelAnchor.anchor(of: buffer, width: Int(mask.width), height: Int(mask.height)) {
                textureLabelPointValue = NSPoint(x: CGFloat(mask.upLeftX) + anchor.pointValue.x, y: CGFloat(mask.upLeftY) + anchor.pointValue.y)
            } else {
                textureLabelPointValue = lowerRightPoint()
            }
            textureLabelPointBuffer = buffer
            hasTextureLabelPoint = true
        }
        return textureLabelPointValue
    }

    // MARK: Smoothed outline

    @discardableResult
    @objc public func splinePoints() -> NSMutableArray! {
        return splinePoints(5.0)
    }

    @objc(splinePoints:)
    @discardableResult
    public func splinePoints(_ scale: Float) -> NSMutableArray! {
        return splinePoints(scale, correspondingSegmentArray: nil)
    }

    /// The outline smoothed when the ROI is a spline (an open or closed
    /// polygon or a pencil of three points or more), with the segment each
    /// point comes from; the points otherwise. A polygon being drawn is
    /// smoothed open.
    @objc(splinePoints:correspondingSegmentArray:)
    @discardableResult
    public func splinePoints(_ scale: Float, correspondingSegmentArray: AutoreleasingUnsafeMutablePointer<NSMutableArray?>?) -> NSMutableArray! {
        if !self.isSpline { return self.points }
        if _type != .tOPolygon && _type != .tCPolygon && _type != .tPencil { return self.points }
        if _points.count < 3 { return self.points }

        let localType: ToolMode = mode == ROI_drawing ? .tOPolygon : _type
        var outline = ROI.points(of: _points)
        if localType != .tOPolygon && _points.count > 0 {
            outline.append(ROI.point(_points, 0).point)   // the first point again, to smooth the closing
        }
        let smoothed = ROISpline.smooth(outline, scale: Double(scale))
        let newPoints = ROI.myPoints(smoothed.points)
        if let correspondingSegmentArray {
            let segments = NSMutableArray(capacity: smoothed.segments.count)
            for s in smoothed.segments { segments.add(NSNumber(value: s)) }
            correspondingSegmentArray.pointee = segments
        }
        if newPoints.count == 0 { return self.points }
        return newPoints
    }

    /// The slices of the smoothed outline's points.
    @discardableResult
    @objc public func splineZPositions() -> NSMutableArray! {
        if !self.isSpline { return _zPositions }
        if _type != .tOPolygon && _type != .tCPolygon && _type != .tPencil { return _zPositions }
        if _points.count < 3 { return _zPositions }

        var values: [CGPoint] = []
        for i in 0..<_zPositions.count {
            values.append(NSPoint(x: CGFloat((_zPositions.object(at: i) as! NSNumber).floatValue), y: CGFloat(i)))
        }
        if _type != .tOPolygon {
            values.append(_zPositions.count > 0 ? NSPoint(x: CGFloat((_zPositions.object(at: 0) as! NSNumber).floatValue), y: 0) : .zero)
        }
        let smoothed = ROISpline.smooth(values, scale: 1)
        let newPoints = NSMutableArray()
        for p in smoothed.points { newPoints.add(NSNumber(value: Float(p.x))) }
        return newPoints
    }

    // MARK: Class geometry

    @objc(pointBetweenPoint:and:ratio:)
    @discardableResult
    public class func pointBetweenPoint(_ a: NSPoint, and b: NSPoint, ratio r: Float) -> NSPoint {
        return ROIPlanarGeometry.point(between: a, and: b, ratio: r)
    }

    @objc(lengthBetween:and:)
    @discardableResult
    public class func length(between mesureA: NSPoint, and mesureB: NSPoint) -> Float {
        return ROIPlanarGeometry.length(between: mesureA, and: mesureB)
    }

    @objc(segmentDistToPoint:::)
    @discardableResult
    public class func segmentDist(toPoint segA: NSPoint, _ segB: NSPoint, _ p: NSPoint) -> NSPoint {
        return ROIPlanarGeometry.projection(onSegment: segA, segB, of: p)
    }

    @objc(positionAtDistance:inPolygon:)
    @discardableResult
    public class func position(atDistance distance: Float, inPolygon points: NSArray) -> NSPoint {
        return ROIPlanarGeometry.position(atDistance: distance, along: ROI.points(of: points))
    }

    @objc(resamplePoints:number:)
    @discardableResult
    public class func resamplePoints(_ points: [Any]!, number no: Int32) -> NSMutableArray! {
        return ROI.myPoints(ROIPlanarGeometry.resample(ROI.points(of: (points ?? []) as NSArray), count: Int(Swift.max(no, 0))))
    }

    // MARK: Measurements

    @objc(EllipseArea)
    @discardableResult
    public func ellipseArea() -> Float {
        return ROIPlanarGeometry.area(ofEllipseWithHalfSize: _rect.size)
    }

    @discardableResult
    @objc public func plainArea() -> Float {
        return ROIPlanarGeometry.area(ofMask: mask.buffer, count: Int(mask.width) &* Int(mask.height))
    }

    @objc(Area:)
    @discardableResult
    public func area(_ pts: NSMutableArray) -> Float {
        let outline = ROI.points(of: pts)
        return outline.withUnsafeBufferPointer { ROIPlanarGeometry.area(ofPolygon: $0.baseAddress, count: $0.count) }
    }

    @objc(Area)
    @discardableResult
    public func area() -> Float {
        if _type == .tPlain { return plainArea() }
        return area(self.splinePoints())
    }

    @objc(angleBetween2Lines::::)
    @discardableResult
    public func angleBetween2Lines(_ line1pt1: NSPoint, _ line1pt2: NSPoint, _ line2pt1: NSPoint, _ line2pt2: NSPoint) -> Double {
        return ROIPlanarGeometry.angle(betweenLine: line1pt1, line1pt2, andLine: line2pt1, line2pt2)
    }

    /// The angle at `p1` from `p2` to `p3`, in degrees.
    @objc(Angle:::)
    @discardableResult
    public func angle(_ p2: NSPoint, _ p1: NSPoint, _ p3: NSPoint) -> Float {
        return ROIPlanarGeometry.angle(at: p1, from: p2, to: p3, spacingX: _pixelSpacingX, spacingY: _pixelSpacingY)
    }

    @objc(Magnitude::)
    @discardableResult
    public func magnitude(_ point1: NSPoint, _ point2: NSPoint) -> Float {
        return ROIPlanarGeometry.magnitude(from: point1, to: point2)
    }

    /// In cm, or in pixels without pixel spacing.
    @objc(Length::)
    @discardableResult
    public func length(_ mesureA: NSPoint, _ mesureB: NSPoint) -> Float {
        return length(from: mesureA, to: mesureB, inPixel: false)
    }

    /// In cm, or in pixels without pixel spacing or when `inPixel`.
    @objc(LengthFrom:to:inPixel:)
    @discardableResult
    public func length(from mesureA: NSPoint, to mesureB: NSPoint, inPixel: Bool) -> Float {
        return ROIPlanarGeometry.length(from: mesureA, to: mesureB, spacingX: _pixelSpacingX, spacingY: _pixelSpacingY, inPixels: inPixel)
    }

    /// In cm, or in pixels without pixel spacing; `pixels` receives the length in pixels.
    @objc(MesureLength:pointA:pointB:)
    @discardableResult
    public func mesureLength(_ pixels: UnsafeMutablePointer<Float>?, pointA a: NSPoint, pointB b: NSPoint) -> Float {
        return ROIPlanarGeometry.measureLength(from: a, to: b, spacingX: _pixelSpacingX, spacingY: _pixelSpacingY, pixels: pixels)
    }

    /// The length of a length ROI, in cm, or in pixels without pixel spacing.
    @objc(MesureLength:)
    @discardableResult
    public func mesureLength(_ pixels: UnsafeMutablePointer<Float>!) -> Float {
        return mesureLength(pixels, pointA: (_points.object(at: 0) as! MyPoint).point, pointB: (_points.object(at: 1) as! MyPoint).point)
    }

    /// The length of the outline through `pts`, closed back to its first point when `closed`, in cm or in pixels.
    @objc(perimeterOfPoints:closed:)
    @discardableResult
    public func perimeter(ofPoints pts: NSArray, closed: Bool) -> Float {
        let outline = ROI.points(of: pts)
        return outline.withUnsafeBufferPointer {
            ROIPlanarGeometry.perimeter(of: $0.baseAddress, count: $0.count, closed: closed, spacingX: _pixelSpacingX, spacingY: _pixelSpacingY)
        }
    }

    @objc(ProjectionPointLine:::)
    @discardableResult
    public func projectionPointLine(_ Point: NSPoint, _ startPoint: NSPoint, _ endPoint: NSPoint) -> NSPoint {
        return ROIPlanarGeometry.projection(of: Point, onLineFrom: startPoint, to: endPoint)
    }

    @objc(DistancePointLine::::)
    @discardableResult
    public func distancePointLine(_ Point: NSPoint, _ startPoint: NSPoint, _ endPoint: NSPoint, _ Distance: UnsafeMutablePointer<Float>) -> Int32 {
        return ROIPlanarGeometry.distance(from: Point, toSegmentFrom: startPoint, to: endPoint, distance: Distance)
    }

    /// The area in cm2: 0 without pixel spacing.
    @discardableResult
    @objc public func roiArea() -> Float {
        if _pixelSpacingX == 0 && _pixelSpacingY == 0 { return 0 }
        switch _type {
        case .tDynAngle, .tAxis, .tOPolygon, .tCPolygon, .tPencil:
            return Float(Double(area()) * _pixelSpacingX * _pixelSpacingY / 100.0)
        case .tROI:
            return Float(Double(_rect.size.width) * _pixelSpacingX * Double(_rect.size.height) * _pixelSpacingY / 100.0)
        case .tOval:
            return Float(Double(ellipseArea()) * _pixelSpacingX * _pixelSpacingY / 100.0)
        case .tPlain:
            // The painted pixels were counted in a float, which stops at 2^24.
            return Float(Double(Swift.min(plainArea(), 16777216)) * _pixelSpacingX * _pixelSpacingY / 100.0)
        default:
            return 0
        }
    }

    /// The geometric centroid, in pixels.
    @discardableResult
    @objc public func centroid() -> NSPoint {
        if _type == .tROI || _type == .tOval { return _rect.origin }
        let outline = ROI.points(of: self.points)
        return outline.withUnsafeBufferPointer { ROIPlanarGeometry.centroid(of: $0.baseAddress, count: $0.count) }
    }

    // MARK: Values

    /// The pixel values the ROI covers, along a length or inside the others;
    /// `no` receives their number. The caller frees them.
    @objc(dataValuesAsFloatPointer:)
    @discardableResult
    public func dataValues(asFloatPointer no: UnsafeMutablePointer<Int>!) -> UnsafeMutablePointer<Float>! {
        if _type == .tMesure {
            return (self.pix as DCMPix?)?.getLineROIValue(no, self)
        }
        return (self.pix as DCMPix?)?.getROIValue(no, self, nil)
    }

    @discardableResult
    @objc public func dataValues() -> NSMutableArray! {
        let array = NSMutableArray()
        var no = 0
        if let data = dataValues(asFloatPointer: &no) {
            for i in 0..<no { array.add(NSNumber(value: data[i])) }
            free(data)
        }
        return array
    }

    /// The values the label shows, for the ROI manager and the exports.
    @discardableResult
    @objc public func dataString() -> NSMutableDictionary! {
        var array = NSMutableDictionary()
        switch _type {
        case .tOval, .tROI, .tDynAngle, .tTAGT, .tAxis, .tCPolygon, .tOPolygon, .tPencil, .tPlain:
            array = NSMutableDictionary(capacity: 0)
            if rtotal == -1 { computeStatistics(of: self.pix) }

            if _type == .tOval {
                if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                    array["AreaCM2"] = NSNumber(value: Float(Double(ellipseArea()) * _pixelSpacingX * _pixelSpacingY / 100.0))
                } else {
                    array["AreaPIX2"] = NSNumber(value: ellipseArea())
                }
            } else if _type == .tROI {
                if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                    array["AreaCM2"] = NSNumber(value: Float(Double(_rect.size.width) * _pixelSpacingX * Double(_rect.size.height) * _pixelSpacingY / 100.0))
                } else {
                    array["AreaPIX2"] = NSNumber(value: Float(_rect.size.width * _rect.size.height))
                }
            } else {
                if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                    array["AreaCM2"] = NSNumber(value: Float(Double(area()) * _pixelSpacingX * _pixelSpacingY / 100.0))
                } else {
                    array["AreaPIX2"] = NSNumber(value: area())
                }
            }
            array["Mean"] = NSNumber(value: rmean)
            array["MedianAvailable"] = NSNumber(value: self.median.isFinite)
            if self.median.isFinite { array["Median"] = NSNumber(value: self.median) }
            let pix = self.pix as DCMPix?
            array["MedianUnit"] = pix?.suvConverted == true ? "SUV" : (pix?.rescaleType ?? "")
            array["Dev"] = NSNumber(value: rdev)
            array["Total"] = NSNumber(value: rtotal)
            array["Min"] = NSNumber(value: rmin)
            array["Max"] = NSNumber(value: rmax)
            // The fixed spline geometry the displayed length uses.
            array["Length"] = NSNumber(value: perimeter(ofPoints: self.splinePoints(), closed: _type != .tOPolygon))
        case .tAngle:
            array = NSMutableDictionary(capacity: 0)
            array["Angle"] = NSNumber(value: angle((_points.object(at: 0) as! MyPoint).point, (_points.object(at: 1) as! MyPoint).point,
                                                   (_points.object(at: 2) as! MyPoint).point))
        case .tMesure:
            array = NSMutableDictionary(capacity: 0)
            array["Length"] = NSNumber(value: length((_points.object(at: 0) as! MyPoint).point, (_points.object(at: 1) as! MyPoint).point))
        default:
            break
        }
        return array
    }

    /// The mean, sum, deviation, extremes, skewness and kurtosis of `pix` inside the ROI.
    func computeStatistics(of pix: DCMPix?) {
        pix?.computeROI(self, &rmean, &rtotal, &rdev, &rmin, &rmax, &rskewness, &rkurtosis)
    }

    /// The same without skewness and kurtosis.
    func computeMeanAndExtremes(of pix: DCMPix?) {
        pix?.computeROI(self, &rmean, &rtotal, &rdev, &rmin, &rmax)
    }

    // MARK: Calcium scoring

    /// The Agatston cofactor, for a threshold of 90 rather than 130: multislice
    /// CT rather than electron beam.
    @discardableResult
    @objc public func calciumScoreCofactor() -> Int32 {
        if rtotal == -1 { computeMeanAndExtremes(of: self.pix) }
        if _calciumCofactor == 0 {
            _calciumCofactor = (self.pix as DCMPix?)?.calciumCofactor(for: self, threshold: _calciumThreshold) ?? 0
        }
        return _calciumCofactor
    }

    /// The area in mm2 times the cofactor, for overlapping slices times their interval over their thickness.
    @discardableResult
    @objc public func calciumScore() -> Float {
        if rtotal == -1 { computeMeanAndExtremes(of: self.pix) }
        var intervalRatio: Float = 1
        if _curView != nil {
            let pix = self.pix as DCMPix?
            intervalRatio = Float(abs((pix?.sliceInterval ?? 0) / (pix?.sliceThickness ?? 0)))
        } else {
            NSLog("curView == nil")
        }
        if intervalRatio > 1 { intervalRatio = 1 }
        let area = Float(Double(plainArea()) * _pixelSpacingX * _pixelSpacingY)
        return area * Float(calciumScoreCofactor()) * intervalRatio
    }

    /// The area times the slice thickness.
    @discardableResult
    @objc public func calciumVolume() -> Float {
        if rtotal == -1 { computeMeanAndExtremes(of: self.pix) }
        let area = Float(Double(plainArea()) * _pixelSpacingX * _pixelSpacingY)
        return Float(Double(area) * ((self.pix as DCMPix?)?.sliceThickness ?? 0))
    }

    /// The volume times the mean CT density over 250.
    @discardableResult
    @objc public func calciumMass() -> Float {
        if rtotal == -1 { computeMeanAndExtremes(of: self.pix) }
        return Float(abs(Double(calciumVolume() * rmean)) / 250)
    }
}
