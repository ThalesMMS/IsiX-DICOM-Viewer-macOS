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

// What the viewer does to a ROI with the mouse and the ROI tools: pick it by
// its outline, a handle or its label, create it point by point, drag it or one
// of its handles, move, rotate, resize and flip it, add and delete points.
extension ROI {

    /// How far from a point or an outline a click still picks it, in the
    /// view's points.
    static let neighborhoodRadius = 10.0

    /// NSPointInRect: inside, or on the minimum edges, of a rectangle not made standard.
    static func pointInRect(_ p: NSPoint, _ r: NSRect) -> Bool {
        p.x >= r.origin.x && p.x < r.origin.x + r.size.width && p.y >= r.origin.y && p.y < r.origin.y + r.size.height
    }

    /// NSIsEmptyRect.
    static func isEmptyRect(_ r: NSRect) -> Bool {
        !(r.size.width > 0) || !(r.size.height > 0)
    }

    /// Whether MyPoint `p` (or nil) is near `a`, as -isNearToPoint::: answered: NO for nil.
    static func isNear(_ p: Any?, _ a: NSPoint, _ scale: Float, _ ratio: Float) -> Bool {
        (p as? MyPoint)?.isNear(to: a, scale, ratio) ?? false
    }

    func myPoint(_ index: Int) -> MyPoint {
        ROI.point(_points, index)
    }

    // MARK: Picking

    /// The mode a click at `pt` gives the ROI: selected on its outline or
    /// inside it (by its label when `testDrawRect`), selected for
    /// modification on a handle, asleep otherwise. Remembers the handle.
    @objc(clickInROI:::::)
    @discardableResult
    public func click(inROI pt: NSPoint, _ offsetx: Float, _ offsety: Float, _ scale: Float, _ testDrawRect: Bool) -> Int {
        var imode = ROI_sleep
        if _hidden { return ROI_sleep }
        if !_selectable { return ROI_sleep }
        if mode == ROI_drawing { return ROI_sleep }

        _clickInTextBox = false
        previousMode = mode

        let neighborhoodRad = Float(ROI.neighborhoodRadius * Double(view?.roiWindow?.backingScaleFactor ?? 0))
        let backingScaleFactor = self.backingScaleFactor

        if testDrawRect {
            let cPt = view?.convertFromGL2View(pt) ?? .zero
            if ROI.pointInRect(cPt, drawRect) {
                imode = ROI_selected
                _clickInTextBox = true
            }
        } else {
            switch _type {
            case .tLayerROI:
                let p1 = myPoint(0).point, p2 = myPoint(1).point, p3 = myPoint(2).point, p4 = myPoint(3).point
                if isPoint(pt, inRectDefinedByPointA: p1, pointB: p2, pointC: p3, pointD: p4) {
                    if clickHitsLayerPixel(pt, p1, p2, p4, neighborhood: neighborhoodRad) { imode = ROI_selected }
                }
            case .tPlain:
                if pt.x > CGFloat(mask.upLeftX) && pt.x < CGFloat(mask.downRightX) && pt.y > CGFloat(mask.upLeftY) && pt.y < CGFloat(mask.downRightY) {
                    let index = (ROIBrushMask.int32(Double(pt.x)) &- mask.upLeftX) &+ mask.width &* (ROIBrushMask.int32(Double(pt.y)) &- mask.upLeftY)
                    if mask.buffer![Int(index)] > 1 {
                        if mode == ROI_selected || mode == ROI_selectedModify || mode == ROI_drawing {
                            imode = mode
                            // A brush is modified only by the brush tool.
                            if view?.currentTool == .tPlain { imode = ROI_selectedModify }
                        } else {
                            imode = ROI_selected
                        }
                    }
                }
            case .tROI:
                let pts = self.points!
                var distance: Float = 0
                for i in 0..<pts.count {
                    let a = (pts.object(at: i) as! MyPoint).point
                    let b = (pts.object(at: i == pts.count - 1 ? 0 : i + 1) as! MyPoint).point
                    _ = distancePointLine(pt, a, b, &distance)
                    if distance * scale < neighborhoodRad / 2 {
                        imode = ROI_selected
                        break
                    }
                }
            case .t2DPoint:
                let r = neighborhoodRad / scale
                let arect = NSRect(x: _rect.origin.x - CGFloat(r), y: _rect.origin.y - CGFloat(r),
                                   width: CGFloat(neighborhoodRad * 2 / scale), height: CGFloat(neighborhoodRad * 2 / scale))
                if ROI.pointInRect(pt, arect) { imode = ROI_selected }
            case .tText:
                let s = Double(2 * scale)
                let arect = NSRect(x: _rect.origin.x - CGFloat(Double(_rect.size.width) / s), y: _rect.origin.y - CGFloat(Double(_rect.size.height) / s),
                                   width: CGFloat(Double(_rect.size.width) / Double(scale)), height: CGFloat(Double(_rect.size.height) / Double(scale)))
                if ROI.pointInRect(pt, arect) { imode = ROI_selected }
            case .tArrow, .tMesure:
                var distance: Float = 0
                _ = distancePointLine(pt, myPoint(0).point, myPoint(1).point, &distance)
                if distance * scale < neighborhoodRad / 2 { imode = ROI_selected }
            case .tOval, .tOPolygon, .tAngle:
                let splinePoints = self.splinePoints(scale)!
                if splinePoints.count > 0 {
                    for i in 0..<(splinePoints.count - 1) {
                        var distance: Float = 0
                        _ = distancePointLine(pt, ROI.point(splinePoints, i).point, ROI.point(splinePoints, i + 1).point, &distance)
                        if distance * scale < neighborhoodRad / 2 {
                            imode = ROI_selected
                            break
                        }
                    }
                    // The centre.
                    if imode != ROI_selected {
                        let distance = magnitude(pt, _rect.origin)
                        if distance * scale < neighborhoodRad / 2 { imode = ROI_selected }
                    }
                }
            case .tDynAngle, .tAxis, .tCPolygon, .tPencil, .tTAGT:
                var distance: Float = 0
                let splinePoints = self.splinePoints(scale)!
                if splinePoints.count > 0 {
                    var i = 0
                    while i < splinePoints.count - 1 {
                        _ = distancePointLine(pt, ROI.point(splinePoints, i).point, ROI.point(splinePoints, i + 1).point, &distance)
                        if distance * scale < neighborhoodRad / 2 {
                            imode = ROI_selected
                            break
                        }
                        i += 1
                    }
                    _ = distancePointLine(pt, ROI.point(splinePoints, i).point, ROI.point(splinePoints, 0).point, &distance)
                    if distance * scale < neighborhoodRad / 2 { imode = ROI_selected }
                }
            default:
                break
            }
        }

        // The handles.
        let tempPoint = MyPoint(point: pt)
        let ratio = viewPixelRatio
        let near = scale / backingScaleFactor
        switch _type {
        case .tOval:
            selectedModifyPoint = 0
            let o = _rect.origin, s = _rect.size
            if tempPoint.isNear(to: NSPoint(x: o.x - s.width, y: o.y - s.height), near, ratio) { selectedModifyPoint = 1 }
            if tempPoint.isNear(to: NSPoint(x: o.x - s.width, y: o.y + s.height), near, ratio) { selectedModifyPoint = 2 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y + s.height), near, ratio) { selectedModifyPoint = 3 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y - s.height), near, ratio) { selectedModifyPoint = 4 }
            if selectedModifyPoint != 0 { imode = ROI_selectedModify }
        case .tROI:
            selectedModifyPoint = 0
            let o = _rect.origin, s = _rect.size
            if tempPoint.isNear(to: NSPoint(x: o.x, y: o.y), near, ratio) { selectedModifyPoint = 1 }
            if tempPoint.isNear(to: NSPoint(x: o.x, y: o.y + s.height), near, ratio) { selectedModifyPoint = 2 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y + s.height), near, ratio) { selectedModifyPoint = 3 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y), near, ratio) { selectedModifyPoint = 4 }
            if selectedModifyPoint != 0 { imode = ROI_selectedModify }
        case .tAngle, .tArrow, .tMesure, .tDynAngle, .tAxis, .tCPolygon, .tOPolygon, .tPencil, .tTAGT:
            if mode != ROI_selectedModify { selectedModifyPoint = -1 }
            for i in 0..<_points.count where myPoint(i).isNear(to: pt, near, ratio) {
                imode = ROI_selectedModify
                selectedModifyPoint = i
            }
        default:
            break
        }
        _clickPoint = pt
        return imode
    }

    /// Whether a pixel of the layer's image that is not transparent is within
    /// `neighborhood` of the click, in the image's own pixels.
    private func clickHitsLayerPixel(_ pt: NSPoint, _ p1: NSPoint, _ p2: NSPoint, _ p4: NSPoint, neighborhood neighborhoodRad: Float) -> Bool {
        guard let tiff = _layerImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return false }
        let width = Float(bitmap.pixelsWide), height = Float(bitmap.pixelsHigh)

        // The base vectors of the layer image's coordinates.
        var v = NSPoint(x: p2.x - p1.x, y: p2.y - p1.y)
        var l = Float((v.y * v.y).addingProduct(v.x, v.x).squareRoot())
        v.x /= CGFloat(l)
        v.y /= CGFloat(l)
        let scaleRatio = width / l   // the ROI as shown, to the image as stored
        var w = NSPoint(x: p4.x - p1.x, y: p4.y - p1.y)
        l = Float((w.y * w.y).addingProduct(w.x, w.x).squareRoot())
        w.x /= CGFloat(l)
        w.y /= CGFloat(l)

        // The clicked point in the layer image's coordinates.
        let c = NSPoint(x: pt.x - p1.x, y: pt.y - p1.y)
        var x: Float, y: Float
        if v.x != 0 {
            let r = v.y / v.x
            y = Float(c.y.addingProduct(-c.x, r) / w.y.addingProduct(-w.x, r))
            x = Float(c.x.addingProduct(-CGFloat(y), w.x) / v.x)
        } else {
            let r = v.x / v.y
            y = Float(c.x.addingProduct(-c.y, r) / w.x.addingProduct(-w.y, r))
            x = Float(c.y.addingProduct(-CGFloat(y), w.y) / v.y)
        }
        x *= scaleRatio
        y *= scaleRatio

        // A pixel around it that is not transparent.
        var i = ROIBrushMask.int32(Double(-neighborhoodRad))
        while Float(i) <= neighborhoodRad {
            var j = ROIBrushMask.int32(Double(-neighborhoodRad))
            while Float(j) <= neighborhoodRad {
                let xi = x + Float(i), yj = y + Float(j)
                if xi >= 0.0 && yj >= 0.0 && xi < width && yj < height,
                   let pixel = bitmap.colorAt(x: Int(ROIBrushMask.int32(Double(xi))), y: Int(ROIBrushMask.int32(Double(yj)))),
                   pixel.alphaComponent > 0.0 {
                    return true
                }
                j += 1
            }
            i += 1
        }
        return false
    }

    /// Marks the handle under the pointer; the view is drawn again when it changes.
    @objc(displayPointUnderMouse::::)
    public func displayPointUnderMouse(_ pt: NSPoint, _ offsetx: Float, _ offsety: Float, _ scale: Float) {
        if _hidden { return }
        let tempPoint = MyPoint(point: pt)
        let previousPointUnderMouse = PointUnderMouse
        PointUnderMouse = -1
        let near = scale / backingScaleFactor
        let ratio = viewPixelRatio
        let o = _rect.origin, s = _rect.size

        switch _type {
        case .tOval:
            if tempPoint.isNear(to: NSPoint(x: o.x - s.width, y: o.y - s.height), near, ratio) { PointUnderMouse = 1 }
            if tempPoint.isNear(to: NSPoint(x: o.x - s.width, y: o.y + s.height), near, ratio) { PointUnderMouse = 2 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y + s.height), near, ratio) { PointUnderMouse = 3 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y - s.height), near, ratio) { PointUnderMouse = 4 }
        case .tROI:
            if tempPoint.isNear(to: NSPoint(x: o.x, y: o.y), near, ratio) { PointUnderMouse = 1 }
            if tempPoint.isNear(to: NSPoint(x: o.x, y: o.y + s.height), near, ratio) { PointUnderMouse = 2 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y + s.height), near, ratio) { PointUnderMouse = 3 }
            if tempPoint.isNear(to: NSPoint(x: o.x + s.width, y: o.y), near, ratio) { PointUnderMouse = 4 }
        case .tAngle, .tArrow, .tMesure, .tDynAngle, .tAxis, .tCPolygon, .tOPolygon, .tPencil, .tTAGT:
            for i in 0..<_points.count where myPoint(i).isNear(to: pt, near, ratio) {
                PointUnderMouse = Int32(i)
            }
        default:
            break
        }
        if PointUnderMouse != previousPointUnderMouse {
            view?.setNeedsDisplay(true)
        }
    }

    /// Adds a point to a polygon or a pencil where its outline passes under
    /// the click, unless a point is already there.
    @objc(addPointUnderMouse:scale:)
    public func addPointUnderMouse(_ pt: NSPoint, scale: Float) {
        let backingScaleFactor = self.backingScaleFactor
        switch _type {
        case .tOPolygon, .tCPolygon, .tPencil:
            var nearPoint = false
            for case let p as MyPoint in _points where p.isNear(to: pt, scale / backingScaleFactor, viewPixelRatio) {
                nearPoint = true
            }
            if !nearPoint {
                var distance: Float = 0
                var correspondingSegments: NSMutableArray?
                let splinePoints = self.splinePoints(scale, correspondingSegmentArray: &correspondingSegments)!
                if splinePoints.count > 0 {
                    for i in 0..<(splinePoints.count - 1) {
                        _ = distancePointLine(pt, ROI.point(splinePoints, i).point, ROI.point(splinePoints, i + 1).point, &distance)
                        if distance * scale < 5.0 {
                            // Without a spline, the segments are not known: the point goes second.
                            let segment = (correspondingSegments?.object(at: i) as? NSNumber)?.int32Value ?? 0
                            _points.insert(MyPoint(point: pt), at: Int(segment) + 1)
                            break
                        }
                    }
                }
            }
        default:
            break
        }
    }

    // MARK: Creation and dragging

    /// The mouse down in the view's current image.
    @objc(mouseRoiDown::)
    @discardableResult
    public func mouseRoiDown(_ pt: NSPoint, _ scale: Float) -> Bool {
        return mouseRoiDown(pt, Int32(view?.curImage ?? 0), scale)
    }

    /// The mouse down that creates the ROI, or adds a point to it: true while
    /// the ROI is still being drawn.
    @objc(mouseRoiDown:::)
    @discardableResult
    public func mouseRoiDown(_ pt: NSPoint, _ slice: Int32, _ scale: Float) -> Bool {
        roiLock?.lock()
        defer { roiLock?.unlock() }
        var result = false
        if let exception = ROI.objcTry({ result = mouseRoiDown(in: pt, slice, scale) }) {
            NSLog("**** mouseRoiDown exception %@", exception)
        }
        return result
    }

    @objc(mouseRoiDownIn:::)
    @discardableResult
    func mouseRoiDown(in point: NSPoint, _ slice: Int32, _ scale: Float) -> Bool {
        var pt = point
        let backingScaleFactor = self.backingScaleFactor

        if !_selectable {
            mode = ROI_sleep
            return false
        }
        if mode == ROI_sleep { mode = ROI_drawing }
        if _locked { return false }
        if _comments?.isEqual(to: "morphing generated") == true { self.comments = ROI.empty as String }
        postChange()

        if _type == .tPlain {
            if textureFirstPoint == 0 {
                mask.upLeftX = ROIBrushMask.int32(Double(pt.x))
                mask.upLeftY = ROIBrushMask.int32(Double(pt.y))
                mask.downRightX = ROIBrushMask.int32(Double(pt.x) + 1)
                mask.downRightY = ROIBrushMask.int32(Double(pt.y) + 1)
                textureFirstPoint = 1
                mask.width = 2
                mask.height = 2
                mask.buffer = malloc(4)?.assumingMemoryBound(to: UInt8.self)
                if let buffer = mask.buffer { memset(buffer, 0, 4) }
                textureBufferHasChanged()
                mode = ROI_drawing
            } else {
                mode = ROI_selected
            }
            previousPoint = pt
            return false
        }

        if _type == .t2DPoint {
            _rect = NSRect(origin: pt, size: .zero)
            mode = ROI_selected
            return false
        } else if _type == .tText {
            _rect.size = textFrameSize()
            _rect.origin = pt
            if _pixelSpacingX != 0 && _pixelSpacingY != 0 {
                _rect.size.height *= CGFloat(_pixelSpacingX / _pixelSpacingY)
            }
            mode = ROI_selected
            return false
        } else if _type == .tOval || _type == .tROI {
            _rect = NSRect(origin: pt, size: .zero)
            mode = ROI_drawing
            return false
        } else if _type == .tArrow || _type == .tMesure {
            _points.add(MyPoint(point: pt))
            _points.add(MyPoint(point: pt))
            mode = ROI_drawing
            return false
        } else if _type == .tTAGT {
            let o = pt
            // B, C, then A, the main line.
            pt = o; pt.x += CGFloat(20 / scale)
            _points.add(MyPoint(point: pt))
            pt.y += CGFloat(40 / scale)
            _points.add(MyPoint(point: pt))
            pt = o; pt.x += CGFloat(40 / scale)
            _points.add(MyPoint(point: pt))
            pt.y += CGFloat(40 / scale)
            _points.add(MyPoint(point: pt))
            pt = o
            _points.add(MyPoint(point: pt))
            pt.x += CGFloat(100 / scale)
            _points.add(MyPoint(point: pt))
            _ = valid()
            mode = ROI_selected
            return false
        } else {
            let near = scale / (_thickness * backingScaleFactor)
            // A closed polygon is completed on its first vertex, without a duplicate of it.
            if _type == .tCPolygon && mode == ROI_drawing && _points.count >= 3 && myPoint(0).isNear(to: pt, near, viewPixelRatio) {
                mode = ROI_selected
            } else if !ROI.isNear(_points.lastObject, pt, near, viewPixelRatio) {
                _points.add(MyPoint(point: pt))
                _zPositions.add(NSNumber(value: slice))
                _clickPoint = pt
            } else {
                // A click on the last point stops the drawing.
                mode = ROI_selected
            }
            if _type == .tAngle && _points.count > 2 { mode = ROI_selected }
        }

        if _type == .tPencil { return false }
        return mode == ROI_drawing
    }

    /// The drag of the mouse: draws the ROI further, or moves the handle being modified.
    @objc(mouseRoiDragged:::)
    @discardableResult
    public func mouseRoiDragged(_ pt: NSPoint, _ modifier: UInt32, _ scale: Float) -> Bool {
        if _locked { return false }
        if !_selectable { return false }

        roiLock?.lock()
        // The drag runs once a mouse event: called through a C function and
        // its context, its Objective-C exceptions are caught without the
        // block and the error objcTry(_:) would allocate each time.
        struct Drag {
            unowned(unsafe) let roi: ROI
            let pt: NSPoint, modifier: UInt32, scale: Float, backingScaleFactor: Float
            var action = false
        }
        var call = Drag(roi: self, pt: pt, modifier: modifier, scale: scale, backingScaleFactor: self.backingScaleFactor)
        let exception = withUnsafeMutablePointer(to: &call) { pointer in
            HorosObjCPerformFunction({ context in
                let call = context!.assumingMemoryBound(to: Drag.self)
                call.pointee.action = call.pointee.roi.drag(to: call.pointee.pt, call.pointee.modifier, call.pointee.scale,
                                                            backingScaleFactor: call.pointee.backingScaleFactor)
            }, pointer)
        }
        if let exception {
            NSLog("***** mouseRoiDragged exception: %@", exception)
        }
        roiLock?.unlock()
        return call.action
    }

    private func drag(to pt: NSPoint, _ modifier: UInt32, _ scale: Float, backingScaleFactor: Float) -> Bool {
        var action = false
        let constrained = ROIDragConstraint.isConstrained(modifierFlags: modifier)
        let ratio = ROIDragConstraint.pixelRatio(spacingX: _pixelSpacingX, spacingY: _pixelSpacingY)

        if _type == .tText || _type == .t2DPoint {
            action = false
        } else if _type == .tPlain {
            switch mode {
            case ROI_selectedModify, ROI_drawing:
                _thickness = ROI.settings.regionThickness
                var value: UInt8 = view?.eraserFlag == true ? 0x00 : 0xFF
                if modifier & UInt32(NSEvent.ModifierFlags.command.rawValue) != 0 && modifier & UInt32(NSEvent.ModifierFlags.shift.rawValue) == 0 {
                    value = value == 0xFF ? 0 : 0xFF
                }
                if previousPoint.x == -1000 && previousPoint.y == -1000 { previousPoint = pt }
                mask.paint(from: previousPoint, to: pt, thickness: _thickness, value: value) { textureBufferHasChanged() }
                previousPoint = pt
                action = true
                forgetStatistics()
                textureBufferHasChanged()
            case ROI_selected:
                action = false
            default:
                break
            }
        } else if _type == .tOval || _type == .tROI {
            switch mode {
            case ROI_drawing:
                _rect.size.width = pt.x - _rect.origin.x
                _rect.size.height = pt.y - _rect.origin.y
                // The side follows the pointer's own direction: a square
                // stays in the quadrant it is dragged to.
                if constrained {
                    _rect.size.width = CGFloat(ROIDragConstraint.constrainedWidth(Double(_rect.size.width), height: Double(_rect.size.height), ratio: ratio))
                }
                forgetStatistics()
                action = true
            case ROI_selected:
                action = false
            case ROI_selectedModify:
                forgetStatistics()
                if _type == .tROI {
                    var leftUp = _rect.origin
                    var rightUp = NSPoint(x: _rect.origin.x + _rect.size.width, y: _rect.origin.y)
                    var leftDown = NSPoint(x: _rect.origin.x, y: _rect.origin.y + _rect.size.height)
                    var rightDown = NSPoint(x: _rect.origin.x + _rect.size.width, y: _rect.origin.y + _rect.size.height)
                    switch selectedModifyPoint {
                    case 1: leftUp = pt; rightUp.y = pt.y; leftDown.x = pt.x
                    case 4: rightUp = pt; leftUp.y = pt.y; rightDown.x = pt.x
                    case 3: rightDown = pt; rightUp.x = pt.x; leftDown.y = pt.y
                    case 2: leftDown = pt; leftUp.x = pt.x; rightDown.y = pt.y
                    default: break
                    }
                    _ = (rightUp, leftDown)
                    _rect = NSRect(x: leftUp.x, y: leftUp.y, width: rightDown.x - leftUp.x, height: rightDown.y - leftUp.y)
                    action = true
                } else {
                    _rect.size.height = pt.y - _rect.origin.y
                    _rect.size.width = constrained ? CGFloat(Double(_rect.size.height) * ratio) : pt.x - _rect.origin.x
                    action = true
                }
            default:
                break
            }
        } else if _type == .tPencil {
            switch mode {
            case ROI_drawing:
                if !ROI.isNear(_points.lastObject, pt, scale / (_thickness * backingScaleFactor), viewPixelRatio) {
                    _points.add(MyPoint(point: pt))
                    _clickPoint = pt
                    forgetStatistics()
                    action = true
                }
            case ROI_selected:
                action = false
            case ROI_selectedModify:
                if selectedModifyPoint >= 0 { myPoint(selectedModifyPoint).point = pt }
                forgetStatistics()
                action = true
            default:
                break
            }
        } else {
            if _type == .tLayerROI { _clickPoint = pt }
            switch mode {
            case ROI_drawing:
                // The point goes where the pointer is: Shift alone shows the
                // lens and constrains no angle.
                (_points.lastObject as? MyPoint)?.point = pt
                if _type == .tMesure && _points.count == 2 && constrained {
                    (_points.lastObject as? MyPoint)?.point = ROIDragConstraint.constrainedLengthEnd(from: myPoint(0).point, to: pt, ratio: ratio)
                }
                forgetStatistics()
                action = true
            case ROI_selected:
                action = false
            case ROI_selectedModify:
                if selectedModifyPoint >= 0 {
                    myPoint(selectedModifyPoint).point = pt
                    if _type == .tMesure && _points.count == 2 && constrained {
                        let other = myPoint(selectedModifyPoint != 0 ? 0 : 1).point
                        myPoint(selectedModifyPoint).point = ROIDragConstraint.constrainedLengthEnd(from: other, to: pt, ratio: ratio)
                    }
                }
                forgetStatistics()
                action = true
            default:
                break
            }
        }

        _ = valid()
        if action {
            if _comments?.isEqual(to: "morphing generated") == true { self.comments = ROI.empty as String }
            postChange()
        }
        return action
    }

    /// The mouse up: a ROI being drawn is complete, a handle released; a click
    /// on the outline that did not move adds a point there.
    @objc(mouseRoiUp:scaleValue:)
    @discardableResult
    public func mouseRoiUp(_ pt: NSPoint, scaleValue: Float) -> Bool {
        postChange(["action": "mouseUp"])
        previousPoint = NSPoint(x: -1000, y: -1000)

        if _type == .tOval || _type == .tROI || _type == .tText || _type == .tArrow || _type == .tMesure || _type == .tPencil
            || _type == .t2DPoint || _type == .tPlain {
            _ = reduceTextureIfPossible()
            if mode == ROI_drawing {
                forgetStatistics()
                postChange(["action": "mouseUp"])
                mode = ROI_selected
                return false
            }
        } else {
            if mode == ROI_selectedModify { mode = ROI_selected }
        }

        if _clickPoint.x == pt.x && _clickPoint.y == pt.y && previousMode == mode && (mode == ROI_selected || mode == ROI_selectedModify) {
            addPointUnderMouse(pt, scale: scaleValue)
        }
        return true
    }

    @objc(mouseRoiUp:)
    @discardableResult
    public func mouseRoiUp(_ pt: NSPoint) -> Bool {
        return mouseRoiUp(pt, scaleValue: 1)
    }

    // MARK: Moving and transforming

    @objc(roiMove::)
    public func roiMove(_ offset: NSPoint, _ sendNotification: Bool) {
        if _locked { return }
        guard mode == ROI_selected else { return }
        switch _type {
        case .tOval, .tText, .t2DPoint, .tROI:
            _rect.origin.x += offset.x
            _rect.origin.y += offset.y
        case .tDynAngle, .tAxis, .tCPolygon, .tOPolygon, .tMesure, .tArrow, .tAngle, .tPencil, .tLayerROI, .tTAGT:
            for i in 0..<_points.count { myPoint(i).move(Float(offset.x), Float(offset.y)) }
        case .tPlain:
            mask.upLeftX &+= ROIBrushMask.int32(Double(offset.x))
            mask.upLeftY &+= ROIBrushMask.int32(Double(offset.y))
            mask.downRightX &+= ROIBrushMask.int32(Double(offset.x))
            mask.downRightY &+= ROIBrushMask.int32(Double(offset.y))
        default:
            break
        }
        if sendNotification {
            forgetStatistics()
            postChange()
        }
    }

    @objc(roiMove:)
    public func roiMove(_ offset: NSPoint) {
        roiMove(offset, true)
    }

    /// A rectangle or an oval rotated, resized or flipped becomes the closed
    /// polygon of its outline.
    private func becomePolygon(of pts: NSMutableArray) {
        if _type == .tROI || _type == .tOval {
            _type = .tCPolygon
            _points = NSMutableArray(array: pts)
        }
    }

    /// Flips the ROI about its centroid, vertically or horizontally.
    @objc(flipVertically:)
    public func flipVertically(_ vertically: Bool) {
        if _locked { return }
        let pts = self.points!
        if _type == .tROI { self.isSpline = false }
        guard pts.count > 0 else { return }
        becomePolygon(of: pts)
        let centroid = self.centroid()
        for case let pt as MyPoint in pts {
            let newX: Float, newY: Float
            if vertically {
                newX = pt.x
                newY = Float(-(Double(pt.y) - Double(centroid.y)) + Double(centroid.y))
            } else {
                newX = Float(-(Double(pt.x) - Double(centroid.x)) + Double(centroid.x))
                newY = pt.y
            }
            pt.point = NSPoint(x: CGFloat(newX), y: CGFloat(newY))
        }
        forgetStatistics()
        postChange()
    }

    /// Rotates the ROI by `angle` degrees about `center`, in the patient's proportions.
    @objc(rotate::)
    public func rotate(_ angle: Float, _ center: NSPoint) {
        if _locked { return }
        let pts = self.points!
        if _type == .tROI { self.isSpline = false }
        guard pts.count > 0 else { return }
        let theta = Double(ROI.deg2rad * angle)
        becomePolygon(of: pts)
        let intXCenter = Float(center.x), intYCenter = Float(center.y)
        var ratio = Float((self.pix as DCMPix?)?.pixelRatio ?? 0)
        if ratio == 0 { ratio = 1.0 }
        let c = cos(theta), s = sin(theta), r = Double(ratio)
        for case let pt as MyPoint in pts {
            let dx = Double(pt.x - intXCenter), dy = Double(pt.y - intYCenter)
            let newX = Float((-(s * dy * r)).addingProduct(c, dx))
            let newY = Float((c * dy * r).addingProduct(s, dx))
            pt.point = NSPoint(x: CGFloat(newX + intXCenter), y: CGFloat(newY / ratio + intYCenter))
        }
        forgetStatistics()
        postChange()
    }

    @discardableResult
    @objc public func canResize() -> Bool {
        return _type == .tLayerROI ? canResizeLayer : true
    }

    /// Scales the ROI by `factor` about `center`.
    @objc(resize::)
    public func resize(_ factor: Float, _ center: NSPoint) {
        if !canResize() { return }
        if _locked { return }
        let pts = self.points!
        guard pts.count > 0 else { return }
        let intXCenter = Float(center.x), intYCenter = Float(center.y)
        if _type == .tROI || _type == .tOval {
            _rect.origin.y = CGFloat(Double(intYCenter).addingProduct(Double(_rect.origin.y) - Double(intYCenter), Double(factor)))
            _rect.origin.x = CGFloat(Double(intXCenter).addingProduct(Double(_rect.origin.x) - Double(intXCenter), Double(factor)))
            _rect.size.width *= CGFloat(factor)
            _rect.size.height *= CGFloat(factor)
        } else {
            for case let pt as MyPoint in pts {
                let newX = (pt.x - intXCenter) * factor
                let newY = (pt.y - intYCenter) * factor
                pt.point = NSPoint(x: CGFloat(newX + intXCenter), y: CGFloat(newY + intYCenter))
            }
        }
        forgetStatistics()
        postChange()
    }

    // MARK: Validity and points

    /// Whether the ROI is complete enough to keep. Makes a rectangle's,
    /// oval's or text's size positive, and puts TAGT's B and C lines on A.
    @discardableResult
    @objc public func valid() -> Bool {
        if mode == ROI_drawing { return true }
        switch _type {
        case .tPlain:
            if plainArea() == 0 { return false }
        case .tOval:
            if _rect.size.width < 0 { _rect.size.width = -_rect.size.width }
            if _rect.size.height < 0 { _rect.size.height = -_rect.size.height }
            if _rect.size.width < 0.2 { return false }
            if _rect.size.height < 0.2 { return false }
        case .t2DPoint:
            if _rect.size.width < 0 {
                _rect.origin.x = _rect.origin.x + _rect.size.width
                _rect.size.width = 0
            }
            if _rect.size.height < 0 {
                _rect.origin.y = _rect.origin.y + _rect.size.height
                _rect.size.height = 0
            }
        case .tText, .tROI:
            if _rect.size.width < 0 {
                _rect.origin.x = _rect.origin.x + _rect.size.width
                _rect.size.width = -_rect.size.width
            }
            if _rect.size.height < 0 {
                _rect.origin.y = _rect.origin.y + _rect.size.height
                _rect.size.height = -_rect.size.height
            }
            if _rect.size.width < 0.2 { return false }
            if _rect.size.height < 0.2 { return false }
        case .tCPolygon, .tOPolygon, .tPencil, .tAngle:
            if _points.count < 3 { return false }
        case .tMesure, .tArrow:
            if _points.count < 2 { return false }
            if abs(myPoint(0).x - myPoint(1).x) < 0.2 && abs(myPoint(0).y - myPoint(1).y) < 0.2 { return false }
        case .tDynAngle, .tAxis:
            if _points.count < 4 { return false }
        case .tTAGT:
            if _points.count < 6 { return false }
            // B (0-1) and C (2-3) start on the main line A (4-5).
            _points.replaceObject(at: 0, with: MyPoint(point: ROIPlanarGeometry.projection(onSegment: myPoint(4).point, myPoint(5).point, of: myPoint(1).point)))
            _points.replaceObject(at: 2, with: MyPoint(point: ROIPlanarGeometry.projection(onSegment: myPoint(4).point, myPoint(5).point, of: myPoint(3).point)))
        default:
            break
        }
        return true
    }

    /// The statistics and the brush's label point are computed again when next asked.
    @objc public func recompute() {
        forgetStatistics()
        hasTextureLabelPoint = false
    }

    /// Deletes the selected point, or the last one, or empties the frame of a
    /// ROI without points. Answers whether the ROI is still valid.
    @discardableResult
    @objc public func deleteSelectedPoint() -> Bool {
        if _hidden { return false }
        if _locked { return false }
        var deletedAllPoints = false
        switch _type {
        case .tPlain:
            return false
        case .tText, .t2DPoint, .tOval, .tROI:
            _rect.size = .zero
        case .tMesure, .tArrow, .tCPolygon, .tOPolygon, .tPencil:
            let index = mode == ROI_selectedModify ? selectedModifyPoint : _points.count - 1
            if index >= 0 && index < _points.count {
                _points.removeObject(at: index)
                if index < _zPositions.count { _zPositions.removeObject(at: index) }
            }
            if selectedModifyPoint >= _points.count { selectedModifyPoint = _points.count - 1 }
            deletedAllPoints = _points.count == 0
        case .tDynAngle, .tAxis, .tTAGT:
            if selectedModifyPoint > 3 {
                if mode == ROI_selectedModify {
                    _points.removeObject(at: selectedModifyPoint)
                } else {
                    _points.removeLastObject()
                }
                if UInt(bitPattern: selectedModifyPoint) >= UInt(_points.count) { selectedModifyPoint = _points.count - 1 }
            }
        default:
            break
        }
        postChange()
        return !deletedAllPoints && valid()
    }

    /// Moves the label by `o`. Its first move starts from where it is shown,
    /// so that a label pushed from its anchor by the edge does not jump back.
    @objc(setTextBoxOffset:)
    public func setTextBoxOffset(_ o: NSPoint) {
        if offsetTextBox_x == 0 && offsetTextBox_y == 0, let view, !ROI.isEmptyRect(drawRect) {
            let displayed = view.convertFromView2GL(NSPoint(x: drawRect.origin.x - 8, y: drawRect.origin.y - 8))
            let anchor = view.convertFromView2GL(originAnchor)
            offsetTextBox_x = Float(displayed.x - anchor.x)
            offsetTextBox_y = Float(displayed.y - anchor.y)
        }
        offsetTextBox_x = Float(Double(offsetTextBox_x) + Double(o.x))
        offsetTextBox_y = Float(Double(offsetTextBox_y) + Double(o.y))
    }

    /// Runs `body` as an @try block: the NSException it raises is returned.
    static func objcTry(_ body: () -> Void) -> NSException? {
        do {
            try HorosObjCException.perform(body)
        } catch {
            return (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
        }
        return nil
    }
}
