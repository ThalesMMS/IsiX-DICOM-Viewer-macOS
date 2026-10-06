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

/// (int)v of the former C on arm64: truncation toward zero, saturated, NaN as 0.
private func cInt32(_ v: CGFloat) -> Int32 {
    if v.isNaN { return 0 }
    if v >= 2147483647 { return .max }
    if v <= -2147483648 { return .min }
    return Int32(v)
}

/// The opacity curve editor of the 3D viewers and of the 2D viewer's thick
/// slab, and the opacity tables built from its points.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OpacityTransferView.h> are those of the former class, the class of
/// the opacity editor in VR.xib and Viewer.xib. The points are strings
/// "{x, y}", x offset by 1000, as the OPACITY presets keep them.
@objc(OpacityTransferView)
public final class OpacityTransferView: NSView {
    @IBOutlet private var position: NSTextField?

    /// nil for a view decoded from an archive, which the former -initWithFrame:
    /// alone did not prepare.
    private var points: NSMutableArray?

    private var curIndex: Int = 0

    private var red = [UInt8](repeating: 0, count: 256)
    private var green = [UInt8](repeating: 0, count: 256)
    private var blue = [UInt8](repeating: 0, count: 256)

    public override init(frame: NSRect) {
        super.init(frame: frame)

        curIndex = -1
        points = NSMutableArray()

        for i in 0 ..< 256 {
            red[i] = UInt8(i)
            green[i] = UInt8(i)
            blue[i] = UInt8(i)
        }
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func mouseDragged(with event: NSEvent) {
        let eventLocation = event.locationInWindow
        var center: NSPoint

        if curIndex >= 0 {
            center = self.convert(eventLocation, from: nil)

            if center.y < 0 || center.y > self.bounds.size.height {
                points?.removeObject(at: curIndex)
                curIndex = -1

                position?.stringValue = ""
            } else {
                if center.x < 0 { center.x = 0 }
                if center.x > 512 { center.x = 512 }

                if center.y < 0 { center.y = 0 }
                if center.y > 100 { center.y = 100 }

                let curPt = NSPoint(x: 1000 + center.x / 2.0, y: center.y / 100.0)
                let ptString = NSStringFromPoint(curPt) as NSString

                points?.replaceObject(at: curIndex, with: ptString)
                points?.sort(using: #selector(NSString.compare(_:)))
                curIndex = points?.index(of: ptString) ?? 0

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
            var curPt = NSPointFromString(points?.object(at: i) as? String ?? "")

            curPt.x -= 1000

            if center.x / 2 >= curPt.x - 2 && center.x / 2 <= curPt.x + 2 { // We found a point!
                found = true
                curIndex = i

                break
            }
        }

        if found == false {
            var newPt = NSPoint(x: center.x / 2.0, y: center.y / 100.0)

            if newPt.x < 0 { newPt.x = 0 }
            if newPt.x > 256 { newPt.x = 256 }
            if newPt.y < 0 { newPt.y = 0 }
            if newPt.y > 1.0 { newPt.y = 1.0 }
            newPt.x += 1000

            let newPtString = NSStringFromPoint(newPt) as NSString

            points?.add(newPtString)
            points?.sort(using: #selector(NSString.compare(_:)))
            curIndex = points?.index(of: newPtString) ?? 0
        }

        position?.intValue = cInt32(center.x / 2)

        self.needsDisplay = true
    }

    @objc public func getPoints() -> NSMutableArray? {
        return points
    }

    @objc(tableWith4096Entries:)
    public class func tableWith4096Entries(_ pointsArray: NSArray?) -> NSData {
        var x: Int32
        var cur: Int32
        var last: Int32 = 0
        var entries256 = [Float](repeating: 0, count: 4097)
        var prevPoint = NSPoint(x: 1000, y: 0.0)

        for loopItem1 in pointsArray ?? NSArray() {
            var curPoint = NSPointFromString(loopItem1 as? String ?? "")

            curPoint.x -= 1000

            cur = cInt32(curPoint.x)

            cur = cur &* 16

            x = 0
            while x < cur &- last {
                set(&entries256, Int(last) + Int(x), Float(prevPoint.y + ((curPoint.y - prevPoint.y) * CGFloat(x) / CGFloat(cur &- last))))
                x += 1
            }

            prevPoint = curPoint
            last = cur
        }

        cur = 4096
        let curPoint = NSPoint(x: 1256, y: 1.0)
        x = 0
        while x < cur &- last {
            set(&entries256, Int(last) + Int(x), Float(prevPoint.y + ((curPoint.y - prevPoint.y) * CGFloat(x) / CGFloat(cur &- last))))
            x += 1
        }

        return entries256.withUnsafeBytes { NSData(bytes: $0.baseAddress, length: 4096 * MemoryLayout<Float>.size) }
    }

    @objc(tableWith256Entries:)
    public class func tableWith256Entries(_ pointsArray: NSArray?) -> NSData {
        var x: Int32
        var cur: Int32
        var last: Int32 = 0
        var entries256 = [Float](repeating: 0, count: 256)
        var prevPoint = NSPoint(x: 1000, y: 0.0)

        for loopItem in pointsArray ?? NSArray() {
            var curPoint = NSPointFromString(loopItem as? String ?? "")

            curPoint.x -= 1000

            cur = cInt32(curPoint.x)

            x = 0
            while x < cur &- last {
                set(&entries256, Int(last) + Int(x), Float(prevPoint.y + ((curPoint.y - prevPoint.y) * CGFloat(x) / CGFloat(cur &- last))))
                x += 1
            }

            prevPoint = curPoint
            last = cur
        }

        x = 0
        while x < 256 &- last {
            set(&entries256, Int(last) + Int(x), 1.0)
            x += 1
        }

        return entries256.withUnsafeBytes { NSData(bytes: $0.baseAddress, length: 256 * MemoryLayout<Float>.size) }
    }

    /// entries[index] = value. The former C array was written without a
    /// check; an index outside it, which only points outside the editor's
    /// range give, is not written.
    private static func set(_ entries: inout [Float], _ index: Int, _ value: Float) {
        if index >= 0 && index < entries.count {
            entries[index] = value
        }
    }

    @IBAction public func renderButton(_ sender: Any?) {
        NotificationCenter.default.post(name: .OsirixOpacityChanged, object: self, userInfo: nil)
    }

    @objc(setCurrentCLUT:::)
    public func setCurrentCLUT(_ r: UnsafeMutablePointer<UInt8>?, _ g: UnsafeMutablePointer<UInt8>?, _ b: UnsafeMutablePointer<UInt8>?) {
        guard let r = r, let g = g, let b = b else { return }

        for i in 0 ..< 256 {
            red[i] = r[i]
            green[i] = g[i]
            blue[i] = b[i]
        }
    }

    public override func draw(_ rect: NSRect) {
        NSColor.white.set()
        self.bounds.fill(using: .copy) // NSRectFill

        var crect: NSRect
        var curPoint = NSPoint.zero

        let courbe = NSBezierPath()

        for i in 0 ..< 256 {
            crect = NSRect(x: CGFloat(i * 2), y: 100, width: 2, height: 10)
            NSColor(calibratedRed: CGFloat(red[i]) / 255.0, green: CGFloat(green[i]) / 255.0, blue: CGFloat(blue[i]) / 255.0, alpha: 1.0).set()
            crect.fill(using: .copy)
        }

        courbe.move(to: NSPoint(x: 0, y: 0))

        let count = points?.count ?? 0
        for i in 0 ..< count {
            curPoint = NSPointFromString(points?.object(at: i) as? String ?? "")

            curPoint.x -= 1000
            curPoint.x *= 2.0
            curPoint.y *= 100.0

            if i == 0 {
                if curPoint.x == 0 {
                    courbe.move(to: curPoint)
                } else {
                    courbe.move(to: NSPoint(x: 0, y: 0))
                }
            }

            courbe.line(to: curPoint)

            crect = NSRect(x: curPoint.x - 3, y: curPoint.y - 3, width: 6, height: 6)
            NSColor.red.set()
            crect.fill(using: .copy)
        }

        if curPoint.x != 512 || count == 0 { courbe.line(to: NSPoint(x: 512, y: 100)) }

        NSColor.black.set()
        courbe.lineWidth = 2
        courbe.stroke()

        NSColor.black.set()
        NSBezierPath.stroke(self.bounds)
    }
}
