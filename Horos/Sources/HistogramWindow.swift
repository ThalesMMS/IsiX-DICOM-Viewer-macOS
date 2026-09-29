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

/// Window Controller for histogram display
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/HistogramWindow.h> (with HISTOSIZE) are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it.
@objc(HistoWindow)
public final class HistoWindow: NSWindowController {
    /// Retained, as before.
    private var roi: ROI?
    /// YES from -windowWillClose: on, as the flag of OSIWindowController: the
    /// lookups by nib name that reuse this window skip it, since its
    /// -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    private var data: UnsafeMutablePointer<Float>?
    /// The former `float histoData[HISTOSIZE]` instance variable, whose address
    /// the histogram view keeps.
    private let histoData: UnsafeMutablePointer<Float> = {
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Int(HISTOSIZE))
        buffer.initialize(repeating: 0, count: Int(HISTOSIZE))
        return buffer
    }()
    private var maxValue: Float = 0
    private var minValue: Float = 0
    private var dataSize = 0

    @IBOutlet var histo: HistoView!
    @IBOutlet var binSlider: NSSlider!
    @IBOutlet var binText: NSTextField!
    @IBOutlet var maxText: NSTextField!

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(initWithROI:)
    public convenience init(roi iroi: ROI!) {
        self.init(windowNibName: "Histogram")

        window?.setFrameAutosaveName("HistogramWindow")

        data = nil
        roi = iroi

        window?.title = String(format: NSLocalizedString("Histogram of '%@' ROI", comment: ""), (roi?.name ?? "(null)") as NSString)

        histo?.setCurROI(roi)

        if let data = data { free(data) }
        data = roi?.dataValues(asFloatPointer: &dataSize)

        let fullwl = roiChartLong(Double(roi?.pix?.fullwl ?? 0))
        let fullww = roiChartLong(Double(roi?.pix?.fullww ?? 0))

        minValue = Float(fullwl &- fullww / 2)
        maxValue = Float(fullwl &+ fullww / 2)

        changeBin(binSlider)

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(removeROI(_:)),
                       name: NSNotification.Name.OsirixRemoveROI,
                       object: nil)

        nc.addObserver(self,
                       selector: #selector(roiChange(_:)),
                       name: NSNotification.Name.OsirixROIChange,
                       object: nil)

        nc.addObserver(self,
                       selector: #selector(changeWLWW(_:)),
                       name: NSNotification.Name.OsirixChangeWLWW,
                       object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let data = data {
            free(data)
        }

        histoData.deallocate()
    }

    @objc(removeROI:)
    func removeROI(_ note: NSNotification!) {
        if (note.object as AnyObject?) === roi {
            window?.close()
        }
    }

    @objc(changeWLWW:)
    func changeWLWW(_ note: NSNotification!) {
        if (note.object as AnyObject?) === roi?.pix {
            changeBin(binSlider)
        }
    }

    @objc(roiChange:)
    func roiChange(_ note: NSNotification!) {
        if (note.object as AnyObject?) === roi {
            if let data = data { free(data) }
            data = roi?.dataValues(asFloatPointer: &dataSize)

            let fullwl = roiChartLong(Double(roi?.pix?.fullwl ?? 0))
            let fullww = roiChartLong(Double(roi?.pix?.fullww ?? 0))

            minValue = Float(fullwl &- fullww / 2)
            maxValue = Float(fullwl &+ fullww / 2)

            changeBin(binSlider)
        }
    }

    @IBAction @objc(changeBin:)
    public func changeBin(_ sender: Any!) {
        var max = 0

        for i in 0..<Int(HISTOSIZE) { histoData[i] = 0 }

        var i = 0
        while i < dataSize {
            var dL = roiChartLong(Double(((data![i] - minValue) * Float(HISTOSIZE)) / (maxValue - minValue)))

            if dL < 0 {
                dL = 0
            }

            if dL > Int(HISTOSIZE) - 1 {
                dL = Int(HISTOSIZE) - 1
            }

            histoData[dL] += 1

            if histoData[dL] > Float(max) {
                max = roiChartLong(Double(histoData[dL]))
            }
            i += 1
        }

        // [sender intValue] of the bin slider.
        let binValue = (sender as? NSControl)?.intValue ?? 0

        histo?.setRange(roiChartLong(Double(minValue)), roiChartLong(Double(maxValue)))
        histo?.setMaxValue(Float(max), dataSize)
        histo?.setData(histoData, Int(HISTOSIZE), Int(binValue))

        maxText?.intValue = Int32(truncatingIfNeeded: max)

        binText?.intValue = roiChartInt(Double((Float(binValue) * (maxValue - minValue)) / Float(HISTOSIZE)))
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        closing = true
        window?.acceptsMouseMovedEvents = false

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(curROI)
    public func curROI() -> ROI! {
        return roi
    }
}
