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
import Accelerate
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

    // MARK: - Instance variables of the former plugin SDK

    // Plugins built for the former Horos or OsiriX SDK read and write these at
    // the offset the application exports for each, so each is a stored field
    // of this class with the C declaration's type, never private, lazy, weak
    // or observed. The slab is the composer's: the view writes here, when a
    // message changes them, the copies of what the composer answers (the
    // size, the spacing, the window, the two sources, the flags, the colour
    // and opacity tables) and reads none of them back; a plugin's write
    // changes nothing of the composite.
    var _imageBlendingPtr: UnsafeMutablePointer<Float>?, _imagePtr: UnsafeMutablePointer<Float>?
    var _width = 0, _height = 0, _count = 0
    var _spaceX: Float = 0, _spaceY: Float = 0, _thickness: Float = 0, _ww: Float = 0, _wl: Float = 0
    var _flipData = false, _lowQuality = false, _isRGB = false
    var _tableFloatR = IsiXThickSlabTable(), _tableFloatG = IsiXThickSlabTable(), _tableFloatB = IsiXThickSlabTable()
    var _opacityTable = IsiXThickSlabTable()
    // Without state in this view: the fused series' tables and the conversion
    // buffers are inside the composer, the composite's planes and bounds are
    // locals of its threads, and the VTK objects of the former ray caster
    // (pointers to C++ objects, never retained) are gone. Kept at zero and nil.
    var _tableBlendingFloatR = IsiXThickSlabTable(), _tableBlendingFloatG = IsiXThickSlabTable(), _tableBlendingFloatB = IsiXThickSlabTable()
    unowned(unsafe) var _volume: AnyObject?, _volumeProperty: AnyObject?, _colorTransferFunction: AnyObject?, _reader: AnyObject?
    unowned(unsafe) var _opacityTransferFunction: AnyObject?, _flipReader: AnyObject?, _aRenderer: AnyObject?, _aCamera: AnyObject?
    // Declared only by older copies of the SDK's headers: the composite
    // function and the mapper of the former ray caster, C++ objects of a
    // library the slab is no longer drawn with.
    unowned(unsafe) var _compositeFunction: AnyObject?, _volumeMapper: AnyObject?
    var _srcf = vImage_Buffer(), _dst8 = vImage_Buffer(), _srcfBlending = vImage_Buffer(), _dst8Blending = vImage_Buffer()
    var _dstFloatR: UnsafeMutablePointer<Float>?, _dstFloatG: UnsafeMutablePointer<Float>?, _dstFloatB: UnsafeMutablePointer<Float>?
    var _ifrom = 0, _ito = 0, _isize = 0
    var _processorsLock: NSLock?, _numberOfThreadsForCompute: Int32 = 0

    /// Writes the copies of the composer's numbers and flags.
    private func copyComposerState() {
        _width = composer.width
        _height = composer.height
        _count = composer.count
        _spaceX = composer.spaceX
        _spaceY = composer.spaceY
        _thickness = composer.thickness
        _wl = composer.windowLevel
        _ww = composer.windowWidth
        _flipData = composer.flipData
        _lowQuality = composer.lowQuality
        _isRGB = composer.isRGB
    }

    /// A table of the composer as the SDK's float[256].
    private static func table(_ values: [Float]) -> IsiXThickSlabTable {
        var table = IsiXThickSlabTable()
        withUnsafeMutableBytes(of: &table) { bytes in
            values.withUnsafeBytes { bytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(bytes.count))) }
        }
        return table
    }

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
        copyComposerState()
    }

    @objc(setWLWW::)
    public func setWLWW(_ l: Float, _ w: Float) {
        composer.setWLWW(l, w)
        copyComposerState()
    }

    @objc(setBlendingWLWW::)
    public func setBlendingWLWW(_ l: Float, _ w: Float) {
        composer.setBlendingWLWW(l, w)
        copyComposerState()
    }

    @objc(setCLUT:::)
    public func setCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        composer.setCLUT(r, g, b)
        _tableFloatR = Self.table(composer.red)
        _tableFloatG = Self.table(composer.green)
        _tableFloatB = Self.table(composer.blue)
        copyComposerState()
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
        _imagePtr = i
        copyComposerState()
    }

    @objc(setFlip:)
    public func setFlip(_ f: Bool) {
        composer.flipData = f
        _flipData = f
    }

    @objc(setLowQuality:)
    public func setLowQuality(_ q: Bool) {
        composer.lowQuality = q
        _lowQuality = q
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
            _opacityTable = Self.table(composer.opacityTable)
        } catch {
            NSLog("ThickSlabVR: %@", error.localizedDescription)
        }
    }

    @objc(setImageBlendingSource:)
    public func setImageBlendingSource(_ i: UnsafeMutablePointer<Float>?) {
        composer.setImageBlendingSource(i)
        _imageBlendingPtr = i
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
