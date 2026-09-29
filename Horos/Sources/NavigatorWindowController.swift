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

/// [[[AppController sharedAppController] viewerScreens] objectAtIndex: 0],
/// which raises without a screen as it did.
private func firstViewerScreen() -> NSScreen? {
    let screens = (AppController.shared()?.viewerScreens() ?? []) as NSArray
    return screens.object(at: 0) as? NSScreen
}

/// Window Controller for the Navigator. The Navigator provides a unrolled view
/// of the selected series (in 3D and in 4D).
///
/// Implemented in Swift since #828: the Objective-C name, the selectors and
/// <Horos/NavigatorWindowController.h> are those of the former class, the
/// File's Owner of Navigator.xib.
@objc(NavigatorWindowController)
public final class NavigatorWindowController: NSWindowController {
    /// The former static `nav`, set by -initWithViewer: and cleared by -dealloc.
    /// It never retained the controller.
    private static unowned(unsafe) var nav: NavigatorWindowController? = nil

    @objc public private(set) var viewerController: ViewerController?
    @IBOutlet @objc public private(set) var navigatorView: NavigatorView?
    @IBOutlet private var scrollview: NSScrollView?
    private var dontReEnter = false

    /// Returns the Navigator Window Controller (which is a unique object).
    @objc(navigatorWindowController)
    public class func navigatorWindowController() -> NavigatorWindowController? {
        return nav
    }

    /// -initWithWindowNibName:@"Navigator", through the Objective-C initializer
    /// the window controllers override.
    @objc(initWithViewer:)
    public convenience init(viewer: ViewerController?) {
        self.init(windowNibName: "Navigator")

        NavigatorWindowController.nav = self

        _ = self.window // generate the awake from nib ! and populates the nib variables like navigatorView

        self.setViewer(viewer)

        NotificationCenter.default.addObserver(self, selector: #selector(closeViewerNotification(_:)), name: NSNotification.Name.OsirixCloseViewer, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(setWindowLevel(_:)), name: NSApplication.willBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(setWindowLevel(_:)), name: NSApplication.willResignActiveNotification, object: nil)
    }

    public override func awakeFromNib() {
        self.window?.acceptsMouseMovedEvents = true
        scrollview?.scrollerStyle = .legacy
    }

    @objc(setViewer:)
    public dynamic func setViewer(_ viewer: ViewerController?) {
        navigatorView?.saveTransformForCurrentViewer()
        var needsUpdate = false
        if viewerController !== viewer {
            viewerController = viewer
            needsUpdate = true
        }

        if (viewerController?.isDataVolumicIn4D(true) ?? false) == false {
            NSLog("unsupported data for 4D")
            self.window?.close()
            return
        }

        if needsUpdate { self.initView() }

        //[navigatorView setViewer];
    }

    @objc(initView)
    public dynamic func initView() {
        navigatorView?.setViewer()
        self.computeMinAndMaxSize()
        self.adjustWindowPosition()
        self.window?.acceptsMouseMovedEvents = true
        _ = self.window?.makeFirstResponder(navigatorView)
    }

    @IBAction public override func showWindow(_ sender: Any?) {
        self.initView()
        super.showWindow(sender)
        ThumbnailsListPanel.checkScreenParameters()
    }

    @objc(closeViewerNotification:)
    private func closeViewerNotification(_ notif: Notification?) {
        //	if( [notif object] == viewerController)
        //	{
        //		[self setViewer: nil];
        //	}

        if ((ViewerController.getDisplayed2DViewers() as NSArray?)?.count ?? 0) == 0 {
            self.window?.close()
        }
    }

    @objc(adjustWindowPositionWithTiling:)
    private func adjustWindowPosition(withTiling: Bool) {
        dontReEnter = true

        let height = cInt32(Double((self.window?.frame ?? .zero).size.height))

        var r = NavigatorView.rect()

        let screen = firstViewerScreen()

        r.origin.y = (screen?.visibleFrame ?? .zero).origin.y
        r.size.height = CGFloat(height) + (self.window?.frame ?? .zero).origin.y - r.origin.y

        if r.size.height > NavigatorView.rect().size.height {
            r.size.height = NavigatorView.rect().size.height
        }

        if r.size.height < CGFloat(navigatorView?.minimumWindowHeight() ?? 0) {
            r.size.height = CGFloat(navigatorView?.minimumWindowHeight() ?? 0)
        }

        self.window?.setFrame(r, display: true)

        if r.size.height != CGFloat(height) && withTiling == true {
            AppController.shared()?.tileWindows(nil)
        }

        dontReEnter = false
    }

    @objc(adjustWindowPosition)
    public dynamic func adjustWindowPosition() {
        return self.adjustWindowPosition(withTiling: true)
    }

    @objc(windowDidMove:)
    private func windowDidMove(_ notification: Notification?) {
        if dontReEnter == false {
            self.adjustWindowPosition(withTiling: true)
        }
    }

    @objc(windowDidResize:)
    private func windowDidResize(_ aNotification: Notification?) {
        if dontReEnter == false {
            self.adjustWindowPosition(withTiling: true)
        }
    }

    @objc(windowWillClose:)
    private func windowWillClose(_ notification: Notification?) {
        self.window?.acceptsMouseMovedEvents = false

        self.window?.orderOut(self)

        // [self autorelease]: balances the alloc of the viewer that opened the
        // Navigator, which never releases the controller.
        _ = Unmanaged.passUnretained(self).autorelease()
    }

    deinit {
        NSLog("NavigatorWindowController dealloc")
        NavigatorWindowController.nav = nil
        NotificationCenter.default.removeObserver(self)
        viewerController = nil
        // The former code sent these after [super dealloc]; Swift runs
        // NSWindowController's dealloc after this body.
        AppController.shared()?.tileWindows(nil)
        ThumbnailsListPanel.checkScreenParameters()
    }

    @objc(computeMinAndMaxSize)
    public dynamic func computeMinAndMaxSize() {
        var maxSize = (navigatorView?.frame ?? .zero).size
        maxSize.height += 16 // 16px for the title bar

        let screen = firstViewerScreen()

        let screenWidth = Float((screen?.frame ?? .zero).size.width)
        maxSize.width = CGFloat(screenWidth)
        if (self.window?.frame ?? .zero).size.width < (navigatorView?.frame ?? .zero).size.width { maxSize.height += 11 } // 11px for the horizontal scroller

        self.window?.maxSize = maxSize

        var minSize = NSMakeSize(CGFloat(navigatorView?.thumbnailWidth ?? 0), CGFloat(navigatorView?.thumbnailHeight ?? 0))
        minSize.height += 16 // 16px for the title bar
        minSize.width = CGFloat(screenWidth)
        if (self.window?.frame ?? .zero).size.width < (navigatorView?.frame ?? .zero).size.width { minSize.height += 11 } // 11px for the horizontal scroller

        self.window?.minSize = minSize
    }

    @objc(setWindowLevel:)
    public dynamic func setWindowLevel(_ notification: Notification?) {
        let name = notification?.name
        if name == NSApplication.willBecomeActiveNotification {
            self.window?.level = .floating
        } else if name == NSApplication.willResignActiveNotification {
            self.window?.level = viewerController?.window?.level ?? NSWindow.Level(rawValue: 0)
        }
    }
}

/// A float converted to int as the arm64 code of the former C did (fcvtzs):
/// toward zero, saturated, NaN to 0; a Swift conversion traps instead.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}
