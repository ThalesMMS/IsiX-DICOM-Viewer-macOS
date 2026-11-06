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
import IsiXVolumeRendering

/// View for Thick Slab Volume Rendering: the view of ThickSlab.xib, whose
/// composite of the 2D viewer's slab is IsiXVolumeRendering's
/// ThickSlabComposer. The opacity table comes from VTK's piecewise function,
/// through its adapter. The Objective-C name and selectors are those of the
/// former class.
@objc(ThickSlabVR)
public final class ThickSlabVR: NSView {
    private let composer = ThickSlabComposer()
    private let opacityFunction = IsiXVTKPiecewiseFunction()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setOpacity(NSArray())
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setOpacity(NSArray())
    }

    deinit {
        NSLog("ThickSlabVR")
    }

    @objc(setImageData:::::::)
    public func setImageData(_ w: Int, _ h: Int, _ c: Int, _ sX: Float, _ sY: Float, _ t: Float, _ flip: Bool) {
        composer.setImageData(w, h, c, sX, sY, t, flip)
    }

    @objc(setWLWW::)
    public func setWLWW(_ l: Float, _ w: Float) {
        composer.setWLWW(l, w)
    }

    @objc(setBlendingWLWW::)
    public func setBlendingWLWW(_ l: Float, _ w: Float) {
        composer.setBlendingWLWW(l, w)
    }

    @objc(setCLUT:::)
    public func setCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        composer.setCLUT(r, g, b)
    }

    @objc(setBlendingCLUT:::)
    public func setBlendingCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        composer.setBlendingCLUT(r, g, b)
    }

    /// The composite, malloc'ed ARGB bytes the caller frees.
    @objc public func renderSlab() -> UnsafeMutablePointer<UInt8>? {
        composer.renderSlab()
    }

    @objc(setImageSource::)
    public func setImageSource(_ i: UnsafeMutablePointer<Float>?, _ c: Int) {
        composer.setImageSource(i, c)
    }

    @objc(setFlip:)
    public func setFlip(_ f: Bool) {
        composer.flipData = f
    }

    @objc(setLowQuality:)
    public func setLowQuality(_ q: Bool) {
        composer.lowQuality = q
    }

    /// The opacity table from the points of an opacity preset ("{x, y}"
    /// strings, x offset by 1000): straight between them, from (0, 0) unless
    /// the first point is at 0, to (255, 1), or to the last point's opacity
    /// when it is at 256.
    @objc(setOpacity:)
    public func setOpacity(_ array: NSArray?) {
        NSLog("Opacity Table")
        let points = (array ?? NSArray()).map { item -> NSPoint in
            var point = NSPointFromString((item as? String) ?? "")
            point.x -= 1000
            return point
        }
        do {
            try opacityFunction.removeAllPoints()
            if let first = points.first {
                if first.x != 0 {
                    try opacityFunction.addPoint(at: 0, value: 0)
                } else {
                    NSLog("start point")
                }
            } else {
                try opacityFunction.addPoint(at: 0, value: 0)
            }
            for point in points {
                try opacityFunction.addPoint(at: Double(point.x), value: Double(point.y))
            }
            if let last = points.last, last.x == 256 {
                try opacityFunction.addPoint(at: 255, value: Double(last.y))
                NSLog("end point")
            } else {
                try opacityFunction.addPoint(at: 255, value: 1)
            }
            var table = [Float](repeating: 0, count: 256)
            try opacityFunction.getValues(&table, count: 256)
            composer.setOpacityTable(table)
        } catch {
            NSLog("ThickSlabVR: %@", error.localizedDescription)
        }
    }

    @objc(setImageBlendingSource:)
    public func setImageBlendingSource(_ i: UnsafeMutablePointer<Float>?) {
        composer.setImageBlendingSource(i)
    }

    /// What renderSlab composes with, for the 2D viewer's Metal path: the
    /// opacity, red, green and blue tables, 256 floats each, in that order.
    @objc public func compositeTables() -> Data {
        composer.compositeTables
    }

    /// NO when setWLWW:: reverses the slices before they are composed.
    @objc public func flipData() -> Bool {
        composer.flipData
    }
}
