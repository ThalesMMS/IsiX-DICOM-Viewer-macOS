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

import CoreGraphics
import Foundation

/// The viewport of an image view: the scale, the pan (`origin`, in backing
/// pixels from the centre of the view, y up), the rotation in degrees, the
/// flips, and the values they had when a drag began. The view (DCMView, in the
/// app) keeps one and applies the rules here; they only compute, exactly as
/// the view's own code did.
public struct ViewportState: Sendable, Equatable {
    public var scale: Float
    public var origin: CGPoint
    public var rotation: Float
    public var xFlipped: Bool
    public var yFlipped: Bool
    /// The scale, the pan and the rotation when the mouse went down.
    public var scaleAtDragStart: Float = 0
    public var originAtDragStart: CGPoint = .zero
    public var rotationAtDragStart: Float = 0

    public init(scale: Float = 0, origin: CGPoint = .zero, rotation: Float = 0, xFlipped: Bool = false, yFlipped: Bool = false) {
        self.scale = scale
        self.origin = origin
        self.rotation = rotation
        self.xFlipped = xFlipped
        self.yFlipped = yFlipped
    }

    // MARK: - Bounds

    /// The scale a view takes when it is given `value`: nil for NaN, which
    /// leaves the scale as it is, else `value` within 0.01 to 100.
    public static func boundedScale(_ value: Float) -> Float? {
        if value.isNaN { return nil }
        var x = value
        if x < 0.01 { x = 0.01 }
        if x > 100 { x = 100 }
        return x
    }

    /// Whether a scale kept centred accepts `value`: 0.01 to 100, not NaN.
    public static func acceptsCentredScale(_ value: Float) -> Bool {
        return !(value < 0.01) && !(value > 100) && !value.isNaN
    }

    /// The pan that keeps the centre of the view on the same point of the
    /// image when the scale goes to `scale`; nil while the scale is 0.
    public func centredOrigin(forScale scale: Float) -> (x: Float, y: Float)? {
        if self.scale == 0 { return nil }
        return (Float((origin.x * CGFloat(scale)) / CGFloat(self.scale)),
                Float((origin.y * CGFloat(scale)) / CGFloat(self.scale)))
    }

    /// One coordinate of the pan: within ±100000, else 0.
    public static func boundedOffset(_ value: Float) -> Float {
        return value > -100000 && value < 100000 ? value : 0
    }

    /// A rotation given in degrees, brought once into 0 to 360.
    public static func normalizedRotation(_ value: Float) -> Float {
        var rotation = value
        if rotation < 0 { rotation += 360 }
        if rotation > 360 { rotation -= 360 }
        return rotation
    }

    // MARK: - Drags

    /// Takes the scale, the pan and the rotation as a drag's start.
    public mutating func beginDrag() {
        scaleAtDragStart = scale
        originAtDragStart = origin
        rotationAtDragStart = rotation
    }

    /// The scale of a zoom drag: the scale at the start plus the vertical
    /// movement `delta` (as the precise mouse applies it), 80 points per unit
    /// for an image 512 pixels wide.
    public func zoomDragScale(delta: Double, imageWidth: Int) -> Float {
        return Float(Double(scaleAtDragStart) + delta / (80.0 * Double(imageWidth) / 512.0))
    }

    /// The pan of a zoom drag once the scale is the new one: the pan at the
    /// start scaled with it, and, when the zoom is centred on the click,
    /// moved so that the point clicked (`click`, in backing pixels of a
    /// drawing of `drawingSize`) stays under the mouse.
    public func zoomDragOrigin(click: CGPoint?, drawingSize: CGSize, deg2rad: Double) -> (x: Float, y: Float) {
        var o = CGPoint.zero
        let scaleValue = CGFloat(scale), startScaleValue = CGFloat(scaleAtDragStart)

        if var oo = click {
            oo.x = (oo.x - drawingSize.width / 2.0) - (((oo.x - drawingSize.width / 2.0) * scaleValue) / startScaleValue)
            oo.y = (oo.y - drawingSize.height / 2.0) - (((oo.y - drawingSize.height / 2.0) * scaleValue) / startScaleValue)

            oo.y = -oo.y

            if xFlipped { oo.x = -oo.x }
            if yFlipped { oo.y = -oo.y }

            let angle = Double(rotation) * deg2rad
            o.x = oo.x * cos(angle) + oo.y * sin(angle)
            o.y = oo.x * sin(angle) - oo.y * cos(angle)
        }

        let originStart = originAtDragStart
        return (Float(((originStart.x * scaleValue) / startScaleValue) + o.x),
                Float(((originStart.y * scaleValue) / startScaleValue) + o.y))
    }

    /// The pan of a translation drag from `start` to `current` (view points),
    /// in backing pixels of `backingScale`, turned and flipped as the image is.
    public func translateDragOrigin(from start: CGPoint, to current: CGPoint, backingScale: Double,
                                    deg2rad: Double) -> (x: Float, y: Float) {
        var xmove = Float(current.x - start.x)
        var ymove = Float(-(current.y - start.y))

        xmove = Float(Double(xmove) * backingScale)
        ymove = Float(Double(ymove) * backingScale)

        if xFlipped { xmove = -xmove }
        if yFlipped { ymove = -ymove }

        let angle = Double(rotation) * deg2rad
        let xx = Float(Double(xmove) * cos(angle) + Double(ymove) * sin(angle))
        let yy = Float(Double(xmove) * sin(angle) - Double(ymove) * cos(angle))

        let originStart = originAtDragStart
        return (Float(originStart.x + CGFloat(xx)), Float(originStart.y + CGFloat(yy)))
    }

    /// The rotation of a rotation drag, the mouse at `point` from the centre
    /// of the view: the rotation at the start plus the mouse's angle, against
    /// the flips, within 0 to 360.
    public func rotateDragRotation(fromCentre point: CGPoint, deg2rad: Double) -> Float {
        var sign: Float = 1
        if xFlipped { sign = -sign }
        if yFlipped { sign = -sign }

        var rot = Float(Double(rotationAtDragStart) + Double(sign) * atan2(point.x, point.y) / deg2rad)

        while rot < 0 { rot += 360 }
        while rot > 360 { rot -= 360 }
        return rot
    }
}
