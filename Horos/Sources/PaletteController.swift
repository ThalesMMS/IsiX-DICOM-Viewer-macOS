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

/// Window Controller for ROI palette: the brush tool panel (PaletteBrush.xib),
/// which switches the viewer's brush between painting and erasing and sets its
/// size.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/PaletteController.h> are those of the former class.
///
/// The viewer creates the palette with alloc/init and keeps no reference to it:
/// the palette releases itself when its window closes (`-windowWillClose:`).
@objc(PaletteController)
public final class PaletteController: NSWindowController, NSWindowDelegate {
    /// Not retained, as the former ivar. The palette closes when this viewer
    /// posts OsirixCloseViewerNotification, from its own -windowWillClose:,
    /// while it is still alive. Nil until -initWithViewer: sets it, after the
    /// nib has loaded.
    private unowned(unsafe) var viewer: ViewerController?
    /// YES from -windowWillClose: on, as the flag of OSIWindowController: the
    /// lookups by nib name that reuse this window skip it, since its
    /// -windowWillClose: autoreleased it.
    @objc(windowWillClose) public private(set) var closing = false

    // Ivars in the former header; the nib sets them by name.
    @IBOutlet var modeControl: NSSegmentedControl!
    @IBOutlet var sizeSlider: NSSlider!
    @IBOutlet var sliderTextValue: NSTextField!

    public override var windowNibName: NSNib.Name? {
        return "PaletteBrush"
    }

    @IBAction @objc(changeBrushSize:)
    public func changeBrushSize(_ sender: Any!) {
        sliderTextValue?.intValue = PaletteController.control(sender)?.intValue ?? 0

        UserDefaults.standard.set(PaletteController.control(sender)?.floatValue ?? 0, forKey: "ROIRegionThickness")
    }

    public override func awakeFromNib() {
        MainActor.assumeIsolated {
            sliderTextValue?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ROIRegionThickness"))

            // init brush size
            sizeSlider?.intValue = Int32(truncatingIfNeeded: UserDefaults.standard.integer(forKey: "ROIRegionThickness"))

            // The nib loads from -initWithViewer: before the viewer is set: this
            // reaches no viewer, as the former message to nil did.
            viewer?.imageView()?.eraserFlag = (modeControl?.selectedSegment ?? 0) != 0
        }
    }

    @IBAction @objc(changeMode:)
    public func changeMode(_ sender: Any!) {
        viewer?.setROIToolTag(.tPlain)

        let selectedSegment = sender.map { unsafeBitCast($0 as AnyObject, to: NSSegmentedControl.self).selectedSegment } ?? 0
        viewer?.imageView()?.eraserFlag = selectedSegment != 0
    }

    /// -initWithWindowNibName:@"PaletteBrush"; the window is loaded here.
    @objc(initWithViewer:)
    public init(viewer v: ViewerController!) {
        super.init(window: nil)

        if UserDefaults.standard.integer(forKey: "ROIRegionThickness") == 0 {
            UserDefaults.standard.set(Float(2.0), forKey: "ROIRegionThickness")
        }

        window?.setFrameAutosaveName("BrushTool")
        window?.delegate = self

        viewer = v
        let nc = NotificationCenter.default

        nc.addObserver(self,
                       selector: #selector(closeViewerNotification(_:)),
                       name: .OsirixCloseViewer,
                       object: nil)

        showWindow(self)

        viewer?.setROIToolTag(.tPlain)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc(CloseViewerNotification:)
    func closeViewerNotification(_ note: Notification!) {
        if (note.object as AnyObject?) === viewer {
            window?.close()
        }
    }

    deinit {
        NSLog("PaletteController dealloc")

        NotificationCenter.default.removeObserver(self)
    }

    @objc public func windowWillClose(_ notification: Notification) {
        closing = true
        window?.acceptsMouseMovedEvents = false

        // The former [self autorelease]: balances the reference the viewer's
        // alloc/init left, once the current autorelease pool drains.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    /// The sender, messaged as a control whatever it is, as the former `id` was.
    private static func control(_ sender: Any?) -> NSControl? {
        return sender.map { unsafeBitCast($0 as AnyObject, to: NSControl.self) }
    }
}
