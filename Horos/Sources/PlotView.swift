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

/// Plot View
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/PlotView.h> are those of the former class.
@objc(PlotView)
public final class PlotView: NSView {
    private var dataArray: UnsafeMutablePointer<Float>?
    private var dataSize = 0
    private var curMousePosition = 0
    /// Not retained, as before. `unowned(unsafe)` and not `weak`: the ROI's
    /// removal notification comes from its -dealloc, and the plot window
    /// still compares it by identity.
    private unowned(unsafe) var curROI: ROI?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        dataArray = nil
        dataSize = 0
        curMousePosition = -1
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

        if curMousePosition < 0 { curMousePosition = 0 }
        if curMousePosition >= dataSize { curMousePosition = dataSize &- 1 }

        curROI?.mousePosMeasure = Float(curMousePosition) / Float(dataSize)
        curROI?.curView?.needsDisplay = true

        needsDisplay = true
    }

    public override func mouseUp(with theEvent: NSEvent) {
        curMousePosition = -1

        curROI?.mousePosMeasure = Float(curMousePosition)
        curROI?.curView?.needsDisplay = true

        needsDisplay = true
    }

    @objc(setData::)
    public func setData(_ array: UnsafeMutablePointer<Float>!, _ size: Int) {
        dataArray = array
        dataSize = size

        needsDisplay = true
    }

    @objc(setCurROI:)
    public func setCurROI(_ r: ROI!) {
        curROI = r
    }

    /// The height of `value` in a plot spanning `minValue` to `maxValue`.
    ///
    /// When every value is the same the span is zero, and the division gave
    /// NaN, which NSBezierPath refuses with an exception that stopped the
    /// application (#753): such a plot, like a NaN value, is drawn at half
    /// height, a horizontal line.
    static func plotY(_ value: Float, minValue: Float, maxValue: Float, height: CGFloat) -> CGFloat {
        let middle = height / 2
        let span = maxValue - minValue
        guard span > 0, span.isFinite else { return middle }
        let yy = (CGFloat(value - minValue) * height) / CGFloat(span)
        return yy.isFinite ? yy : middle
    }

    public override func draw(_ dirtyRect: NSRect) {
        let boundsRect = bounds
        var minValue: Float
        var maxValue: Float

        guard let dataArray = dataArray else { return }
        if dataSize < 2 { return }

        // Fill and frame the view, not the area needing redraw: since macOS 14
        // NSView no longer clips drawing to its bounds.
        let aRect = bounds

        NSColor.white.set()
        aRect.fill(using: .copy)

        minValue = dataArray[0]
        maxValue = dataArray[0]
        for index in 0..<dataSize {
            if minValue > dataArray[index] { minValue = dataArray[index] }
            if maxValue < dataArray[index] { maxValue = dataArray[index] }
        }

        minValue = Float(Double(minValue) - Double(maxValue - minValue) / 10.0)
        maxValue = Float(Double(maxValue) + Double(maxValue - minValue) / 10.0)

        let plotLine = NSBezierPath()

        for index in 0..<dataSize {
            let pix = curROI?.pix
            let fullwl = roiChartLong(Double(pix?.fullwl ?? 0))
            let fullww = roiChartLong(Double(pix?.fullww ?? 0))

            let min = fullwl &- fullww / 2
            let max = fullwl &+ fullww / 2

            let xx = Float((CGFloat(Int32(truncatingIfNeeded: index)) * boundsRect.size.width) / CGFloat(dataSize &- 1))
            let yy = Float(PlotView.plotY(dataArray[index], minValue: minValue, maxValue: maxValue, height: boundsRect.size.height))

            if index == 0 {
                plotLine.move(to: NSMakePoint(CGFloat(xx), CGFloat(yy)))
            } else {
                plotLine.line(to: NSMakePoint(CGFloat(xx), CGFloat(yy)))
            }

            let wl = roiChartLong(Double(pix?.wl ?? 0))
            let ww = roiChartLong(Double(pix?.ww ?? 0))

            var colVal = Float(Double(min) + Double(Int(Int32(truncatingIfNeeded: index)) &* max) / 255.0)

            colVal = colVal - Float(wl &- ww / 2)
            colVal = colVal / Float(ww)

            if colVal < 0 { colVal = 0 }
            if colVal > 1.0 { colVal = 1.0 }

            NSColor(deviceRed: CGFloat(colVal), green: CGFloat(colVal), blue: CGFloat(colVal), alpha: 1.0).set()
        }
        plotLine.lineWidth = 2

        NSColor.black.set()

        plotLine.stroke()

        if curMousePosition != -1 {
            var trace: String
            let paragraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            let boldFont = roiChartTextAttributes(font: NSFont.labelFont(ofSize: 12.0), color: NSColor.black, paragraphStyle: paragraphStyle)

            NSColor.selectedMenuItemColor.set()
            var lineRect = NSMakeRect((CGFloat(curMousePosition) * boundsRect.size.width) / CGFloat(dataSize &- 1), 0, 2, boundsRect.size.height)
            lineRect.fill(using: .copy)

            // The attributes hold the same paragraph style object, as before.
            paragraphStyle.alignment = .center

            trace = String(format: "X: %d", Int32(truncatingIfNeeded: curMousePosition) &+ 1)

            var traceSize = (trace as NSString).size(withAttributes: boldFont)
            var xLabelPosition = lineRect.origin
            xLabelPosition.x += 4
            if lineRect.origin.x + traceSize.width + 2 > boundsRect.size.width {
                xLabelPosition.x = boundsRect.size.width - traceSize.width - 2
            }

            NSColor.white.set()
            NSMakeRect(xLabelPosition.x, xLabelPosition.y, traceSize.width, traceSize.height).fill(using: .copy)
            NSColor.black.set()
            (trace as NSString).draw(at: xLabelPosition, withAttributes: boldFont)

            if lineRect.origin.x - boundsRect.size.width / 2 > 0 {
                paragraphStyle.alignment = .left
            } else {
                paragraphStyle.alignment = .right
            }

            NSColor.selectedMenuItemColor.set()
            lineRect = NSMakeRect(0, PlotView.plotY(dataArray[curMousePosition], minValue: minValue, maxValue: maxValue, height: boundsRect.size.height), boundsRect.size.width, 2)
            lineRect.fill(using: .copy)

            trace = String(format: "Y: %2.2f", Double(dataArray[curMousePosition]))

            var yLabelPosition = lineRect.origin
            yLabelPosition.x += 2
            yLabelPosition.y += 2

            traceSize = (trace as NSString).size(withAttributes: boldFont)
            NSColor.white.set()
            NSMakeRect(yLabelPosition.x, yLabelPosition.y, traceSize.width, traceSize.height).fill(using: .copy)
            (trace as NSString).draw(at: yLabelPosition, withAttributes: boldFont)
        }

        NSColor.black.set()
        aRect.frame(withWidth: 1.0, using: .copy)
    }
}
