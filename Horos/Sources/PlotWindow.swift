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

/// Window Controller for Plot
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/PlotWindow.h> are those of the former class.
///
/// As before, the controller owns itself while its window is open: code that
/// makes one does not release it, and -windowWillClose: autoreleases it.
@objc(PlotWindow)
public final class PlotWindow: NSWindowController {
    /// Not retained, as before. `unowned(unsafe)` and not `weak`: the ROI's
    /// removal notification comes from its -dealloc and is compared with it.
    private unowned(unsafe) var roi: ROI?

    private var data: UnsafeMutablePointer<Float>?
    private var maxValue: Float = 0
    private var minValue: Float = 0
    private var dataSize = 0

    @IBOutlet var plot: PlotView!
    @IBOutlet var maxX: NSTextField!
    @IBOutlet var minY: NSTextField!
    @IBOutlet var maxY: NSTextField!
    @IBOutlet var sizeT: NSTextField!

    /// Overridden so that -initWithWindowNibName: is inherited, unchanged.
    public override init(window: NSWindow?) {
        super.init(window: window)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(refresh)
    func refresh() {
        if let data = data { free(data) }
        data = roi?.dataValues(asFloatPointer: &dataSize)

        // As before, the first value is read even when the ROI has none.
        let values = data!
        var iY = values[0]
        var aY = values[0]
        for i in 0..<Swift.max(dataSize, 0) {
            if iY > values[i] { iY = values[i] }
            if aY < values[i] { aY = values[i] }
        }

        minY?.floatValue = iY
        maxY?.floatValue = aY
        sizeT?.intValue = roiChartInt(Double(aY - iY))

        // %d read the low 32 bits of the long.
        maxX?.stringValue = String(format: NSLocalizedString("%d pixels", comment: ""), Int32(truncatingIfNeeded: dataSize))

        plot?.setData(data, dataSize)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        if let data = data { free(data) }
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
            plot?.needsDisplay = true
        }
    }

    @objc(roiChange:)
    func roiChange(_ note: NSNotification!) {
        if (note.name.rawValue as NSString).isEqual(to: NSNotification.Name.OsirixRecomputeROI.rawValue) || (note.object as AnyObject?) === roi {
            refresh()
        }
    }

    @objc(initWithROI:)
    public convenience init(roi iroi: ROI!) {
        self.init(windowNibName: "Plot")

        window?.setFrameAutosaveName("PlotWindow")

        data = nil
        roi = iroi

        window?.title = String(format: NSLocalizedString("Plot of '%@' line", comment: ""), (roi?.name ?? "(null)") as NSString)

        plot?.setCurROI(roi)

        refresh()

        let fullwl = roiChartLong(Double(roi?.pix?.fullwl ?? 0))
        let fullww = roiChartLong(Double(roi?.pix?.fullww ?? 0))

        minValue = Float(fullwl &- fullww / 2)
        maxValue = Float(fullwl &+ fullww / 2)

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

        nc.addObserver(self,
                       selector: #selector(roiChange(_:)),
                       name: NSNotification.Name.OsirixRecomputeROI,
                       object: nil)
    }

    @objc(windowWillClose:)
    public func windowWillClose(_ notification: NSNotification!) {
        window?.acceptsMouseMovedEvents = false

        // [self autorelease]: the reference the code that made it kept.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc(curROI)
    public func curROI() -> ROI! {
        return roi
    }
}
