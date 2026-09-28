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

import AppKit

// NSRectFill and NSFrameRectWithWidth, which the former views called, draw
// with NSCompositingOperationCopy; the Swift overlay's fill() and
// frame(withWidth:) default to the context's operation, source over, so the
// views pass .copy.

// Conversions the former Objective-C made implicitly, as they behave on arm64,
// where a float or double converts to an integer by truncation toward zero,
// NaN gives 0 and out-of-range values saturate, and an integer division by
// zero gives 0. Swift traps on each of these; the ROI views and windows use
// these instead, so that a degenerate ROI or window level draws as before
// rather than stopping the application.

/// `(long) value`.
func roiChartLong(_ value: Double) -> Int {
    if value.isNaN { return 0 }
    if value >= 9223372036854775807.0 { return Int.max }
    if value <= -9223372036854775808.0 { return Int.min }
    return Int(value)
}

/// `(int) value`.
func roiChartInt(_ value: Double) -> Int32 {
    if value.isNaN { return 0 }
    if value >= 2147483647.0 { return Int32.max }
    if value <= -2147483648.0 { return Int32.min }
    return Int32(value)
}

/// `(unsigned short) value`: converted to 32 bits, then stored in 16.
func roiChartUInt16(_ value: Double) -> UInt16 {
    if value.isNaN || value <= 0 { return 0 }
    let wide: UInt32 = value >= 4294967295.0 ? UInt32.max : UInt32(value)
    return UInt16(truncatingIfNeeded: wide)
}

/// `a / b` for long operands.
func roiChartQuotient(_ a: Int, _ b: Int) -> Int {
    if b == 0 { return 0 }
    if b == -1 { return 0 &- a }
    return a / b
}

/// The attributes `[NSDictionary dictionaryWithObjectsAndKeys: font,
/// NSFontAttributeName, color, NSForegroundColorAttributeName, paragraphStyle,
/// NSParagraphStyleAttributeName, nil]` built: a nil color ended the list.
func roiChartTextAttributes(font: NSFont?, color: NSColor?, paragraphStyle: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
    var attributes: [NSAttributedString.Key: Any] = [:]
    guard let font = font else { return attributes }
    attributes[.font] = font
    guard let color = color else { return attributes }
    attributes[.foregroundColor] = color
    attributes[.paragraphStyle] = paragraphStyle
    return attributes
}

/// View for histogram display.
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/HistoView.h> are those of the former class.
@objc(HistoView)
public final class HistoView: NSView {
    private var dataArray: UnsafeMutablePointer<Float>?
    private var dataSize = 0
    private var bin = 0
    private var curMousePosition = 0
    private var pixels = 0
    private var minV = 0
    private var maxV = 0
    private var maxValue: Float = 0
    /// Retained, as before.
    private var curROI: ROI?

    // The former setters assigned without retaining, and -dealloc released
    // them: a color set from outside was over-released. They are strong now.
    @objc public var backgroundColor: NSColor!
    @objc public var binColor: NSColor!
    @objc public var selectedBinColor: NSColor!
    @objc public var textColor: NSColor!
    @objc public var borderColor: NSColor!

    public override init(frame: NSRect) {
        super.init(frame: frame)
        curMousePosition = -1
        backgroundColor = NSColor.white
        binColor = NSColor.lightGray
        selectedBinColor = NSColor.selectedMenuItemColor
        textColor = NSColor.black
        borderColor = NSColor.gray
    }

    /// The former class did not override -initWithCoder:, so a decoded view
    /// kept its instance variables zeroed.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func mouseDown(with theEvent: NSEvent) {
        mouseDragged(with: theEvent)
    }

    public override func mouseDragged(with theEvent: NSEvent) {
        let boundsRect = bounds
        let loc = convert(theEvent.locationInWindow, from: window?.contentView)

        curMousePosition = roiChartLong(Double((loc.x * CGFloat(dataSize)) / boundsRect.size.width))

        curMousePosition = roiChartQuotient(curMousePosition, bin)
        curMousePosition = curMousePosition &* bin

        if curMousePosition < 0 { curMousePosition = 0 }
        if curMousePosition >= dataSize &- 1 { curMousePosition = dataSize &- 1 }

        needsDisplay = true
    }

    public override func mouseUp(with theEvent: NSEvent) {
        curMousePosition = -1

        needsDisplay = true
    }

    @objc(setData:::)
    public func setData(_ array: UnsafeMutablePointer<Float>!, _ size: Int, _ b: Int) {
        dataArray = array
        dataSize = size
        bin = b

        needsDisplay = true
    }

    @objc(setMaxValue::)
    public func setMaxValue(_ value: Float, _ p: Int) {
        maxValue = value
        pixels = p
    }

    @objc(setCurROI:)
    public func setCurROI(_ r: ROI!) {
        curROI = r
    }

    @objc(setRange::)
    public func setRange(_ mi: Int, _ max: Int) {
        minV = mi
        maxV = max
    }

    public override func draw(_ aRect: NSRect) {
        let boundsRect = bounds
        var noAtMouse: Int32 = 0
        let maxX = Float((boundsRect.origin.x + boundsRect.size.width) / CGFloat(HISTOSIZE))
        let trace: String
        let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
        let boldFont = roiChartTextAttributes(font: NSFont.labelFont(ofSize: 10.0), color: textColor, paragraphStyle: paragraphStyle)
        backgroundColor?.set()
        boundsRect.fill(using: .copy)

        var index = 0
        while index < dataSize {
            var value: Float = 0

            var i = 0
            while i < bin {
                if index &+ i < dataSize { value += dataArray![index &+ i] }
                i += 1
            }

            let height = Float(((CGFloat(value) * boundsRect.size.height) / CGFloat(maxValue)) / CGFloat(bin))

            let histRect = NSMakeRect(CGFloat(Float(index) * maxX), 0, CGFloat(Float(bin) * maxX) + 1.0, CGFloat(height))

            let pix = curROI?.pix
            let fullwl = roiChartLong(Double(pix?.fullwl ?? 0))
            let fullww = roiChartLong(Double(pix?.fullww ?? 0))

            let min = fullwl &- fullww / 2
            let max = fullwl &+ fullww / 2

            let wl = roiChartLong(Double(pix?.wl ?? 0))
            let ww = roiChartLong(Double(pix?.ww ?? 0))

            var colVal = Float(Double(min) + Double(index &* max) / 255.0)

            colVal = colVal - Float(wl &- ww / 2)
            colVal = colVal / Float(ww)

            if colVal < 0 { colVal = 0 }
            if colVal > 1.0 { colVal = 1.0 }

            NSColor(deviceRed: CGFloat(colVal), green: CGFloat(colVal), blue: CGFloat(colVal), alpha: 1.0).set()

            if index == curMousePosition {
                selectedBinColor?.set()
                noAtMouse = roiChartInt(Double(value))
            } else {
                binColor?.set()
            }

            histRect.fill(using: .copy)

            index = index &+ (bin &- 1)
            index += 1
        }

        if curMousePosition != -1 {
            var ss = minV &+ roiChartQuotient(curMousePosition &* (maxV &- minV), dataSize)
            let ee = minV &+ roiChartQuotient((curMousePosition &+ bin) &* (maxV &- minV), dataSize)

            if curMousePosition > 0 {
                ss = ss &+ 1
            }

            // %d read the low 32 bits of each long.
            trace = String(format: NSLocalizedString("Total Pixels: %d\n\nRange:%d/%d\n\nPixels for\nthis range:%d", comment: ""),
                           Int32(truncatingIfNeeded: pixels), Int32(truncatingIfNeeded: ss), Int32(truncatingIfNeeded: ee), noAtMouse)
        } else {
            trace = String(format: NSLocalizedString("Total Pixels: %d", comment: ""), Int32(truncatingIfNeeded: pixels))
        }

        var dstRect = boundsRect
        dstRect.origin.x += 4
        (trace as NSString).draw(in: dstRect, withAttributes: boldFont)

        borderColor?.set()
        boundsRect.frame(withWidth: 1.0, using: .copy)
    }
}
