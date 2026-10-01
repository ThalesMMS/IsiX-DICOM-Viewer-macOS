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

//static int MacOSVersion109orHigher = -1;

// A floor, not the answer. This was the answer when the toolbar was shorter; on
// a current system the icons and their labels need more than a hundred points,
// and what did not fit was the bottom of the labels - the descenders of "Cloud
// Report" and "Key Image" cut off against the windows tiled underneath. AppKit
// says so plainly: the panel's contentLayoutRect came back zero points tall,
// meaning the title bar and the toolbar had already taken everything there was.
// (The former static int fixedHeight; renamed because -fixedHeight is a method.)
fileprivate let fixedHeightFloor: Int = 100
@MainActor fileprivate var measuredHeight: Int = 0

/// Window Controller for Toolbar
///
/// Implemented in Swift since #714: the Objective-C name, the selectors and
/// <Horos/ToolbarPanel.h> are those of the former class, and ToolbarPanel.xib
/// uses the name as File's Owner. The window ordering, level and the hand-off
/// of key and main status to the viewer are unchanged.
@objc(ToolbarPanelController)
public final class ToolbarPanelController: NSWindowController, NSToolbarDelegate {
    /// Retained, as before.
    @objc public private(set) var toolbar: NSToolbar?
    /// Retained, as before; readonly in the former header.
    @objc public private(set) var viewer: ViewerController?

    public override var windowNibName: NSNib.Name? {
        return "ToolbarPanel"
    }

    // How tall the title bar and the toolbar are is AppKit's business: the toolbar
    // style, the system font size and the labels themselves all move it. Asking for
    // the frame that would leave no content at all is asking exactly that.
    @objc(heightForPanelWindow:)
    public class func heightForPanelWindow(_ window: NSWindow?) -> Int {
        guard let window = window else {
            return 0
        }

        let nothing = NSMakeRect(0, 0, NSWidth(window.frame), 0)

        return Int(ceil(NSHeight(window.frameRect(forContentRect: nothing))))
    }

    // The toolbar is the same for every viewer, so the first panel to be asked
    // answers for the class methods too - which the tiling needs, and which have no
    // window of their own to ask.
    @objc public class func panelHeight() -> Int {
        return measuredHeight > fixedHeightFloor ? measuredHeight : fixedHeightFloor
    }

    @objc public func fixedHeight() -> Int {
        let needed = ToolbarPanelController.heightForPanelWindow(self.window)
        if needed > measuredHeight {
            measuredHeight = needed
        }

        return ToolbarPanelController.panelHeight()
    }

    @objc public class func hiddenHeight() -> Int {
        return Int(NSStatusBar.system.thickness)
    }

    @objc public func exposedHeight() -> Int {
        return ToolbarPanelController.exposedHeight()
    }

    @objc public class func exposedHeight() -> Int {
        return ToolbarPanelController.panelHeight() - ToolbarPanelController.hiddenHeight()
    }

    @objc public class func checkForValidToolbar() {
        // Check that a toolbar is visible for all screens
        for s in NSScreen.screens {
            if let v = ViewerController.frontMostDisplayed2DViewer(for: s) {
                // A viewer in full screen keeps its panel away until it leaves it.
                if !(v.toolbarPanel?.window?.toolbar?.customizationPaletteIsRunning ?? false),
                   ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: v.fullScreenON()) {
                    v.toolbarPanel?.window?.orderBack(self)
                }
            }
        }
    }

    @objc(applicationDidChangeScreenParameters:)
    public func applicationDidChangeScreenParameters(_ aNotification: Notification?) {
        // Confined to the area this screen may hold Horos windows on, for the same
        // reason as the thumbnails list: a strip across the whole display would cross
        // whatever the reserved part is for.
        let thisScreen = viewer?.window?.screen
        let screenRect = TilingArea.rect(for: thisScreen, visibleFrame: thisScreen?.visibleFrame ?? NSZeroRect)

        var dstframe = NSZeroRect
        dstframe.size.height = CGFloat(self.fixedHeight())
        dstframe.size.width = screenRect.size.width
        dstframe.origin.x = screenRect.origin.x
        dstframe.origin.y = screenRect.origin.y + screenRect.size.height - dstframe.size.height + CGFloat(ToolbarPanelController.hiddenHeight())

        if !NSEqualRects(dstframe, self.window?.frame ?? NSZeroRect) {
            self.window?.setFrame(dstframe, display: true)
        }
    }

    @objc(toolbarDidChange:)
    public func toolbarDidChange(_ aNotification: Notification?) {
        self.applicationDidChangeScreenParameters(aNotification)
    }

    @objc(initForViewer:withToolbar:)
    public init(forViewer v: ViewerController?, withToolbar t: NSToolbar?) {
        super.init(window: nil)

        toolbar = t
        viewer = v

        self.window?.toolbarStyle = .expanded

        self.window?.animationBehavior = .none
        self.window?.toolbar = toolbar
        self.window?.level = .normal
        self.window?.makeMain()

        toolbar?.isVisible = true
        ToolbarPolicy.adopt(toolbar: toolbar, in: self.window)

        self.applicationDidChangeScreenParameters(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeScreenParameters(_:)), name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        NotificationCenter.default.addObserver(self, selector: #selector(viewerWillClose(_:)), name: .OsirixCloseViewer, object: nil)

        if AppController.hasMacOSXSnowLeopard() {
            self.window?.collectionBehavior = NSWindow.CollectionBehavior(rawValue: 1 << 6) //NSWindowCollectionBehaviorIgnoresCycle
        }

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(toolbarDidChange(_:)), name: NSToolbar.didRemoveItemNotification, object: toolbar)
        NotificationCenter.default.addObserver(self, selector: #selector(toolbarDidChange(_:)), name: NSToolbar.willAddItemNotification, object: toolbar)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidEndSheet(_:)), name: NSWindow.didEndSheetNotification, object: self.window)

        self.window?.safelySetMovable(false)
        self.window?.showsToolbarButton = false
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func close() {
        self.window?.orderOut(self)

        super.close()

        self.window?.toolbar = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc(windowDidBecomeKey:)
    public func windowDidBecomeKey(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            if viewer?.window?.isVisible == true,
               ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: viewer?.fullScreenON() ?? false) {
                if !(self.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    viewer?.window?.makeKeyAndOrderFront(self)
                    self.window?.orderBack(self)
                }
            } else {
                self.window?.orderOut(self)
            }
        }
    }

    @objc(windowDidBecomeMain:)
    public func windowDidBecomeMain(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            if viewer?.window?.isVisible == true,
               ToolbarPolicy.shouldKeepDetachedToolbarVisible(whenFullScreen: viewer?.fullScreenON() ?? false) {
                if !(self.window?.toolbar?.customizationPaletteIsRunning ?? false) {
                    viewer?.window?.makeKeyAndOrderFront(self)
                    self.window?.orderBack(self)
                }
            } else {
                self.window?.orderOut(self)
            }
        }
    }

    /// The customization sheet leaves this panel as the key window, which the
    /// two methods above do not hand back while the sheet runs: once it ends,
    /// the viewer is the key window again (#943).
    @objc(windowDidEndSheet:)
    public func windowDidEndSheet(_ aNotification: Notification?) {
        guard (aNotification?.object as AnyObject?) === self.window,
              let viewer = viewer, !viewer.windowWillClose(), viewer.window?.isVisible == true else { return }
        viewer.window?.makeKeyAndOrderFront(self)
        self.window?.orderBack(self)
    }

    /// Several items of the 2D toolbar have no target (Note, 3D Panel, Flip…)
    /// and look for their action along the responder chain. When this panel is
    /// the key window, that chain holds only the panel and its controller: the
    /// actions go to the viewer's image view, then to the viewer, as they do
    /// from the viewer's window (#943).
    public override func supplementalTarget(forAction action: Selector, sender: Any?) -> Any? {
        if let viewer = viewer, !viewer.windowWillClose() {
            if let view = viewer.imageView(), view.responds(to: action) { return view }
            if viewer.responds(to: action) { return viewer }
        }
        return super.supplementalTarget(forAction: action, sender: sender)
    }

    @objc(viewerWillClose:)
    public func viewerWillClose(_ n: Notification?) {
        if (n?.object as AnyObject?) === viewer {
            self.window?.orderOut(self)
        }
    }
}
