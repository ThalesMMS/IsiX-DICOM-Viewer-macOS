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

/// Window Controller for ROI Volume display.
///
/// Implemented in Swift since #715: the Objective-C name, the selectors and
/// <Horos/ROIVolumeController.h> are those of the former class, the File's
/// Owner of ROIVolume.xib. The messages to the ROIVolumeView go through
/// ROIVolumeViewHostBridge, because ROIVolumeView.h is C++.
@objc(ROIVolumeController)
public final class ROIVolumeController: Window3DController {
    /// The former `IBOutlet ROIVolumeView *view` ivar, which the xib sets
    /// through -setView:. -view stays the one of Window3DController, as before.
    private var roiVolumeView: NSView?
    private var volumeFieldOutlet: NSTextField?
    private var seriesNameOutlet: NSTextField?

    @IBOutlet private var showSurfaces: NSButton?
    @IBOutlet private var showPoints: NSButton?
    @IBOutlet private var showWireframe: NSButton?
    @IBOutlet private var textured: NSButton?
    @IBOutlet private var color: NSButton?
    @IBOutlet private var colorWell: NSColorWell?
    @IBOutlet private var opacity: NSSlider?

    /// Retained, as are the viewer and the ROI of the former ivars.
    private var viewerStorage: ViewerController?
    private var roiStorage: ROI?

    @objc public var volumeField: NSTextField? {
        return volumeFieldOutlet
    }

    @objc public var seriesName: NSTextField? {
        return seriesNameOutlet
    }

    /// Where the xib sets the view outlet.
    @objc(setView:)
    private func setROIVolumeViewOutlet(_ view: NSView?) {
        roiVolumeView = view
    }

    /// Where the xib sets the volumeField outlet.
    @objc(setVolumeField:)
    private func setVolumeFieldOutlet(_ field: NSTextField?) {
        volumeFieldOutlet = field
    }

    /// Where the xib sets the seriesName outlet.
    @objc(setSeriesName:)
    private func setSeriesNameOutlet(_ field: NSTextField?) {
        seriesNameOutlet = field
    }

    public override func viewer() -> ViewerController! {
        return viewerStorage
    }

    @IBAction public func changeParameters(_ sender: Any?) {
        ROIVolumeViewHostBridge.setOpacity(opacity?.floatValue ?? 0,
                                       showPoints: (showPoints?.state ?? .off) != .off,
                                       showSurface: (showSurfaces?.state ?? .off) != .off,
                                       showWireframe: (showWireframe?.state ?? .off) != .off,
                                       texture: (textured?.state ?? .off) != .off,
                                       useColor: (color?.state ?? .off) != .off,
                                       color: colorWell?.color.usingColorSpace(.genericRGB),
                                       ofView: roiVolumeView)
    }

    @IBAction public func reload(_ sender: Any?) {
        _ = ROIVolumeViewHostBridge.renderVolume(ofView: roiVolumeView)

        self.changeParameters(self)
    }

    @objc(CloseViewerNotification:)
    public func CloseViewerNotification(_ note: Notification?) {
        if (note?.object as AnyObject?) === viewerStorage {
            self.window?.close()
        }
    }

    /// [value floatValue] of a statistic, promoted to double as the former
    /// variadic arguments were.
    private static func statistic(_ data: NSDictionary, _ key: String) -> Double {
        return Double((data.value(forKey: key) as AnyObject?)?.floatValue ?? 0)
    }

    /// -initWithWindowNibName:@"ROIVolume", through the Objective-C initializer
    /// the window controllers override. nil when the ROI gives no volume.
    @objc(initWithRoi:viewer:)
    public convenience init?(roi iroi: ROI?, viewer iviewer: ViewerController?) {
        self.init(windowNibName: "ROIVolume")
        self.setViewer(iviewer, roi: iroi)

        self.window?.delegate = self

        guard let data = ROIVolumeViewHostBridge.setPixSource(iroi, ofView: roiVolumeView) as NSDictionary? else {
            return nil
        }

        let s = NSMutableString()

        if let name = iroi?.name, (name as NSString).length > 0 {
            s.append(String(format: NSLocalizedString("%@\r", comment: ""), name))
        }

        let volumeString: String

        // The float compared as a double, as C promoted it.
        if Double((data.object(forKey: "volume") as AnyObject?)?.floatValue ?? 0) < 0.01 {
            volumeString = String(format: NSLocalizedString("Volume : %2.4f mm\u{00B3}", comment: "mm\u{00B3} == mm3"), Double((data.object(forKey: "volume") as AnyObject?)?.floatValue ?? 0) * 1000.0)
        } else {
            volumeString = String(format: NSLocalizedString("Volume : %2.4f cm\u{00B3}", comment: "cm\u{00B3} == mm3"), Double((data.object(forKey: "volume") as AnyObject?)?.floatValue ?? 0))
        }

        s.append(volumeString)

        s.append(String(format: NSLocalizedString("\rMean: %2.4f SDev: %2.4f Total: %2.4f", comment: ""), ROIVolumeController.statistic(data, "mean"), ROIVolumeController.statistic(data, "dev"), ROIVolumeController.statistic(data, "total")))
        s.append(String(format: NSLocalizedString("\rMin: %2.4f Max: %2.4f ", comment: ""), ROIVolumeController.statistic(data, "min"), ROIVolumeController.statistic(data, "max")))
        if data.value(forKey: "skewness") != nil && data.value(forKey: "kurtosis") != nil {
            s.append(String(format: NSLocalizedString("\rSkewness: %2.4f Kurtosis: %2.4f ", comment: ""), ROIVolumeController.statistic(data, "skewness"), ROIVolumeController.statistic(data, "kurtosis")))
        }

        volumeFieldOutlet?.stringValue = s as String
        seriesNameOutlet?.stringValue = volumeString

        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(CloseViewerNotification(_:)),
                       name: .OsirixCloseViewer,
                       object: nil)

        self.changeParameters(self)
    }

    /// viewer = [iviewer retain]; roi = [iroi retain]; of the initializer.
    private func setViewer(_ iviewer: ViewerController?, roi iroi: ROI?) {
        viewerStorage = iviewer
        roiStorage = iroi
    }

    deinit {
        NSLog("Dealloc ROIVolumeController")

        let nc = NotificationCenter.default
        nc.removeObserver(self)
    }

    public override func windowWillClose(_ notification: Notification) {
        self.window?.acceptsMouseMovedEvents = false
        self.window?.delegate = nil

        // Balances the alloc of the caller, which never releases the window controller.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    @objc public func roi() -> ROI? {
        return roiStorage
    }
}
