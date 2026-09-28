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

/// (unsigned char)v of the former C: truncation toward zero, NaN as 0. The
/// editor's colours keep v within 0...255.
private func cUInt8(_ v: CGFloat) -> UInt8 {
    if v.isNaN { return 0 }
    if v >= 2147483647 { return UInt8(truncatingIfNeeded: Int32.max) }
    if v <= -2147483648 { return UInt8(truncatingIfNeeded: Int32.min) }
    return UInt8(truncatingIfNeeded: Int32(v))
}

/// (long)v of the former C: truncation toward zero, saturated, NaN as 0.
private func cLong(_ v: CGFloat) -> Int {
    if v.isNaN { return 0 }
    if v >= 9223372036854775808.0 { return .max }
    if v < -9223372036854775808.0 { return .min }
    return Int(v)
}

/// (int)v of the former C: truncation toward zero, saturated, NaN as 0.
private func cInt32(_ v: CGFloat) -> Int32 {
    if v.isNaN { return 0 }
    if v >= 2147483647 { return .max }
    if v <= -2147483648 { return .min }
    return Int32(v)
}

/// The 8-bit CLUT editor of the 3D viewers and of the 2D viewer: colours at
/// positions 0...256, and the CLUT they interpolate.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/ColorTransferView.h> are those of the former class, the class of the
/// CLUT editor in VR.xib and Viewer.xib. The points are NSNumbers (longs) and
/// the colours arrays of three float NSNumbers, as the CLUT presets keep them.
@objc(ColorTransferView)
public final class ColorTransferView: NSView {
    @IBOutlet private var pick: NSColorWell?
    @IBOutlet private var position: NSTextField?

    /// nil for a view decoded from an archive, which the former -initWithFrame:
    /// alone did not prepare.
    private var colors: NSMutableArray?
    private var points: NSMutableArray?

    private var curIndex: Int = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)

        curIndex = -1
        points = NSMutableArray()
        colors = NSMutableArray()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @IBAction public func renderButton(_ sender: Any?) {
        NotificationCenter.default.post(name: .OsirixCLUTChanged, object: self, userInfo: nil)
    }

    /// [color redComponent], green, blue, of the colour converted to
    /// calibrated RGB; 0 when it cannot be, as messages to nil.
    private static func components(_ color: NSColor?) -> NSArray {
        let newColor = color?.usingColorSpaceName(.calibratedRGB)

        return [NSNumber(value: Float(newColor?.redComponent ?? 0)),
                NSNumber(value: Float(newColor?.greenComponent ?? 0)),
                NSNumber(value: Float(newColor?.blueComponent ?? 0))] as NSArray
    }

    /// [NSColor colorWithCalibratedRed:… alpha: 1.0] of a stored colour.
    private static func color(_ stored: Any?) -> NSColor {
        let color = stored as? NSArray
        func component(_ index: Int) -> CGFloat {
            return CGFloat((color?.object(at: index) as? NSNumber)?.floatValue ?? 0)
        }
        return NSColor(calibratedRed: component(0), green: component(1), blue: component(2), alpha: 1.0)
    }

    @objc(selectPicker:)
    public func selectPicker(_ sender: Any?) {
        if curIndex >= 0 {
            colors?.replaceObject(at: curIndex, with: ColorTransferView.components(pick?.color))
            self.needsDisplay = true
        }
    }

    @objc public func deleteCurrent() {
        points?.removeObject(at: curIndex)
        colors?.removeObject(at: curIndex)
        curIndex = -1

        position?.stringValue = ""

        self.needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let eventLocation = event.locationInWindow

        var center: NSPoint

        if curIndex >= 0 {
            center = self.convert(eventLocation, from: nil)

            if center.x < 0 { center.x = 0 }
            if center.x > 512 { center.x = 512 }

            let curPt = NSNumber(value: cLong(center.x / 2))

            if center.y < 0 || center.y > self.bounds.size.height {
                self.deleteCurrent()
            } else {
                points?.replaceObject(at: curIndex, with: curPt)
                points?.sort(using: #selector(NSNumber.compare(_:)))
                curIndex = points?.index(of: curPt) ?? 0

                position?.intValue = cInt32(center.x / 2)
            }
            self.needsDisplay = true
        }
    }

    public override func mouseDown(with event: NSEvent) {
        let eventLocation = event.locationInWindow
        var found = false

        let center = self.convert(eventLocation, from: nil)

        for i in 0 ..< (points?.count ?? 0) {
            let curPt = (points?.object(at: i) as? NSNumber)?.intValue ?? 0

            if center.x / 2 >= CGFloat(curPt - 2) && center.x / 2 <= CGFloat(curPt + 2) { // We found a point!
                found = true
                curIndex = i

                let color = colors?.object(at: curIndex)

                pick?.color = ColorTransferView.color(color)

                break
            }
        }

        if found == false {
            let newPt = NSNumber(value: cLong(center.x / 2))

            points?.add(newPt)

            points?.sort(using: #selector(NSNumber.compare(_:)))

            curIndex = points?.index(of: newPt) ?? 0

            colors?.insert(ColorTransferView.components(pick?.color), at: curIndex)
        }

        position?.intValue = cInt32(center.x / 2)

        self.needsDisplay = true
    }

    @objc public func getPoints() -> NSMutableArray? {
        return points
    }

    @objc public func getColors() -> NSMutableArray? {
        return colors
    }

    @objc(ConvertCLUT:::)
    public func convertCLUT(_ red: UnsafeMutablePointer<UInt8>?, _ green: UnsafeMutablePointer<UInt8>?, _ blue: UnsafeMutablePointer<UInt8>?) {
        var cur: Int
        var last = 0
        var curColor: NSColor
        var prevColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1.0)

        /// red[index] = …, green, blue: the three tables have 256 entries; an
        /// index outside them, which only a point outside the editor gives, is
        /// not written.
        func write(_ index: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) {
            guard index >= 0 && index < 256 else { return }
            red?[index] = cUInt8(r)
            green?[index] = cUInt8(g)
            blue?[index] = cUInt8(b)
        }

        for i in 0 ..< (points?.count ?? 0) {
            curColor = ColorTransferView.color(colors?.object(at: i))
            cur = (points?.object(at: i) as? NSNumber)?.intValue ?? 0

            var x = 0
            while x < cur - last {
                write(last + x,
                      255.0 * (prevColor.redComponent + ((curColor.redComponent - prevColor.redComponent) * CGFloat(x) / CGFloat(cur - last))),
                      255.0 * (prevColor.greenComponent + ((curColor.greenComponent - prevColor.greenComponent) * CGFloat(x) / CGFloat(cur - last))),
                      255.0 * (prevColor.blueComponent + ((curColor.blueComponent - prevColor.blueComponent) * CGFloat(x) / CGFloat(cur - last))))
                x += 1
            }

            prevColor = curColor
            last = cur
        }

        cur = 256
        curColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1.0)
        var x = 0
        while x < cur - last {
            write(last + x,
                  255.0 * (prevColor.redComponent + ((curColor.redComponent - prevColor.redComponent) * CGFloat(x) / CGFloat(cur - last))),
                  255.0 * (prevColor.greenComponent + ((curColor.greenComponent - prevColor.greenComponent) * CGFloat(x) / CGFloat(cur - last))),
                  255.0 * (prevColor.blueComponent + ((curColor.blueComponent - prevColor.blueComponent) * CGFloat(x) / CGFloat(cur - last))))
            x += 1
        }
    }

    public override func draw(_ rect: NSRect) {
        NSColor.white.set()
        self.bounds.fill(using: .copy) // NSRectFill

        var cur: Int
        var last = 0
        var curColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1.0)
        var prevColor = NSColor(calibratedRed: 0, green: 0, blue: 0, alpha: 1.0)
        var crect = NSRect.zero

        let count = points?.count ?? 0
        // curIndex >= [points count], an NSInteger against an NSUInteger: -1 too.
        if curIndex < 0 || curIndex >= count { curIndex = -1 }

        for i in 0 ..< count {
            curColor = ColorTransferView.color(colors?.object(at: i))
            cur = (points?.object(at: i) as? NSNumber)?.intValue ?? 0

            var x = 0
            while x < cur - last {
                let col = NSColor(calibratedRed: prevColor.redComponent + ((curColor.redComponent - prevColor.redComponent) * CGFloat(x) / CGFloat(cur - last)),
                                  green: prevColor.greenComponent + ((curColor.greenComponent - prevColor.greenComponent) * CGFloat(x) / CGFloat(cur - last)),
                                  blue: prevColor.blueComponent + ((curColor.blueComponent - prevColor.blueComponent) * CGFloat(x) / CGFloat(cur - last)),
                                  alpha: 1.0)

                crect.origin.x = CGFloat((last + x) * 2)
                crect.origin.y = self.bounds.origin.y
                crect.size.width = 2
                crect.size.height = self.bounds.size.height

                col.set()
                crect.fill(using: .copy)
                x += 1
            }

            if i == curIndex {
                NSColor.white.set()
            } else {
                NSColor.black.set()
            }

            crect.fill(using: .copy)

            prevColor = curColor
            last = cur
        }

        cur = 256
        curColor = NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 1.0)
        var x = 0
        while x < cur - last {
            let col = NSColor(calibratedRed: prevColor.redComponent + ((curColor.redComponent - prevColor.redComponent) * CGFloat(x) / CGFloat(cur - last)),
                              green: prevColor.greenComponent + ((curColor.greenComponent - prevColor.greenComponent) * CGFloat(x) / CGFloat(cur - last)),
                              blue: prevColor.blueComponent + ((curColor.blueComponent - prevColor.blueComponent) * CGFloat(x) / CGFloat(cur - last)),
                              alpha: 1.0)

            crect.origin.x = CGFloat((last + x) * 2)
            crect.origin.y = self.bounds.origin.y
            crect.size.width = 2
            crect.size.height = self.bounds.size.height

            col.set()
            crect.fill(using: .copy)
            x += 1
        }

        NSColor.black.set()
        NSBezierPath.stroke(self.bounds)
    }
}
