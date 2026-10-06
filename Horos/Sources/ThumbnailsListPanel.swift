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

/// The screen each borrowed list was last shown on, keyed by the list's address
/// (+[NSValue valueWithPointer:]). Created by the first -setThumbnailsView:viewer:.
@MainActor fileprivate var associatedScreen: NSMutableDictionary?

/// +[NSValue valueWithPointer:] of a view; nil gives the NULL pointer, as before.
fileprivate func pointerKey(_ view: NSView?) -> NSValue {
    return NSValue(pointer: view.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
}

/// The floating series list of one screen: it borrows the front 2D viewer's
/// thumbnails scroll view and keeps itself just above that viewer's window.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/ThumbnailsListPanel.h> are those of the former class, and
/// ThumbnailsList.xib uses the name as File's Owner, which is also the window's
/// delegate. The window ordering, levels and focus hand-off are unchanged.
@objc(ThumbnailsListPanel)
public final class ThumbnailsListPanel: NSWindowController {
    /// The borrowed list, retained.
    @objc public private(set) var thumbnailsView: NSView?
    /// Where the borrowed list came from. Not retained before; weak here, so a
    /// superview that went away is nil rather than a dangling pointer.
    private weak var superView: NSView?
    private var screen: Int
    /// The viewer the list belongs to, retained. Readonly in the former header.
    @objc public private(set) var viewer: ViewerController?

    public override var windowNibName: NSNib.Name? {
        return "ThumbnailsList"
    }

    @objc public class func fixedWidth() -> Int {
        var w: Float = 0

        switch UserDefaults.standard.integer(forKey: "dbFontSize") {
        case -1: w = Float(100 * 0.8)
        case 0: w = 100
        case 1: w = Float(100 * 1.3)
        default: break
        }

        w += 10

        return Int(w)
    }

    @objc public class func checkScreenParameters() {
        for s in NSScreen.screens {
            AppController.thumbnailsListPanel(for: s)?.applicationDidChangeScreenParameters(nil)
        }
    }

    @objc(applicationDidChangeScreenParameters:)
    public func applicationDidChangeScreenParameters(_ aNotification: Notification?) {
        // The former NSUInteger comparison: a negative screen is out of range too.
        if screen < 0 || NSScreen.screens.count <= screen {
            return
        }

        // The area this screen may hold Horos windows on. A list pinned to the left
        // edge of the display would sit in the strip somebody reserved for something
        // else, and the tiling that leaves room for it would be reserving it twice.
        let thisScreen = NSScreen.screens[screen]
        let screenRect = TilingArea.rect(for: thisScreen, visibleFrame: thisScreen.visibleFrame)

        var dstframe = NSZeroRect
        dstframe.size.height = screenRect.size.height
        dstframe.size.width = CGFloat(ThumbnailsListPanel.fixedWidth())
        dstframe.origin.x = screenRect.origin.x
        dstframe.origin.y = screenRect.origin.y
        dstframe.size.height -= CGFloat(ToolbarPanelController.exposedHeight())

        // +navigatorWindowController, sent by name: Swift imports it as init(), which
        // would make a new controller instead of answering the shared one.
        let navigator = (NavigatorWindowController.self as AnyObject).perform(NSSelectorFromString("navigatorWindowController"))?.takeUnretainedValue() as? NavigatorWindowController
        if (navigator?.window?.screen as AnyObject?) === (self.window?.screen as AnyObject?) {
            dstframe.origin.y += navigator?.window?.frame.size.height ?? 0
            dstframe.size.height -= navigator?.window?.frame.size.height ?? 0
        }

        if let window = self.window, !NSEqualRects(window.frame, dstframe) {
            window.setFrame(dstframe, display: true)
        }
    }

    @objc(initForScreen:)
    public init(forScreen s: Int) {
        screen = s

        super.init(window: nil)

        thumbnailsView = nil

        self.window?.animationBehavior = .none
        self.window?.level = .normal

        self.applicationDidChangeScreenParameters(nil)

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidChangeScreenParameters(_:)), name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        NotificationCenter.default.addObserver(self, selector: #selector(viewerWillClose(_:)), name: .OsirixCloseViewer, object: nil)

        if AppController.hasMacOSXSnowLeopard() {
            self.window?.collectionBehavior = NSWindow.CollectionBehavior(rawValue: 1 << 6) //NSWindowCollectionBehaviorIgnoresCycle
        }

        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeMain(_:)), name: NSWindow.didBecomeMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignMain(_:)), name: NSWindow.didResignMainNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: nil)

        self.window?.safelySetMovable(false)

        if self.window == nil {
            UserDefaults.standard.set(false, forKey: "UseFloatingThumbnailsList")
        }
    }

    public required init?(coder: NSCoder) {
        screen = 0
        super.init(coder: coder)
    }

    // Release the borrowed view only after returning it to its owning viewer.
    // This must work even if floating thumbnails were disabled after attachment.
    @objc public func prepareForScreenReconfiguration() {
        if self.isWindowLoaded { (self.window as? ThumbnailsListNSWindow)?.hideForReconfiguration() }
        returnBorrowedList()
    }

    /// Gives the borrowed list back to the view it came from and forgets its
    /// viewer, leaving the window as it is: a list that is lent again at once
    /// does not take the panel off the screen in between.
    public func returnBorrowedList() {
        if let borrowed = thumbnailsView {
            associatedScreen?.removeObject(forKey: pointerKey(borrowed))
            if let superView = superView { superView.addSubview(borrowed) }
            else { borrowed.removeFromSuperview() }
            thumbnailsView = nil
        }
        superView = nil
        viewer = nil
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        self.prepareForScreenReconfiguration()
    }

    @objc(windowDidResignKey:)
    public func windowDidResignKey(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            if self.window?.isVisible == true, let viewer = viewer {
                self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
            }
        }
    }

    @objc(windowDidBecomeKey:)
    public func windowDidBecomeKey(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            if self.window?.isVisible == true {
                if viewer?.window?.isVisible == true {
                    viewer?.window?.makeKeyAndOrderFront(self)
                }

                if let viewer = viewer, (viewer.window?.windowNumber ?? 0) > 0 {
                    self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
                } else {
                    self.window?.orderOut(self)
                }
            }
        } else {
            let window = aNotification?.object as? NSWindow
            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList"),
               let window = window, let candidate = window.windowController as? ViewerController, window.isVisible,
               AppController.thumbnailsListPanel(for: window.screen) === self {
                self.setThumbnailsView(candidate.previewMatrixScrollView(), viewer: candidate)
            }
        }
    }

    @objc(windowDidResignMain:)
    public func windowDidResignMain(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            if self.window?.isVisible == true, let viewer = viewer {
                self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
            }
        }
    }

    @objc(windowDidBecomeMain:)
    public func windowDidBecomeMain(_ aNotification: Notification?) {
        if (aNotification?.object as AnyObject?) === self.window {
            viewer?.window?.makeKeyAndOrderFront(self)

            if self.window?.isVisible == true, let viewer = viewer {
                self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
            }

            return
        }

        let window = aNotification?.object as? NSWindow

        if (window?.level ?? .normal) != .normal {
            return
        }

        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") == false {
            self.window?.orderOut(self)
            return
        }

        //[self checkPosition];

        if let window = window, window.windowController is ViewerController, window.isVisible {
            let screens = NSScreen.screens
            if screen < 0 || screen >= screens.count {
                self.window?.orderOut(self)
                return
            }
            do {
                if (window.screen as AnyObject?) === NSScreen.screens[screen] {
                    if let viewer = viewer, (viewer.window?.windowNumber ?? 0) > 0 {
                        self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
                    }
                } else if !(viewer?.window?.isVisible ?? false) || (viewer?.window?.screen as AnyObject?) !== screens[screen] {
                    self.window?.orderOut(self)
                }
                // Focus on another display does not invalidate this display's viewer
                // or thumbnail panel. Hide only when our own owner is no longer here.
            }
        }

        if let panelWindow = self.window {
            panelWindow.setFrame(panelWindow.frame, display: true)
        }
    }

    @objc(thumbnailsListWillClose:)
    public func thumbnailsListWillClose(_ tb: NSView?) {
        if thumbnailsView === tb {
            self.window?.orderOut(self)

            if let screen = self.window?.screen {
                associatedScreen?.setObject(screen, forKey: pointerKey(thumbnailsView))
            } else {
                associatedScreen?.removeObject(forKey: pointerKey(thumbnailsView))
            }

            associatedScreen?.removeObject(forKey: pointerKey(thumbnailsView))

            thumbnailsView = nil

            viewer = nil
        }
    }

    @objc(viewerWillClose:)
    public func viewerWillClose(_ n: Notification?) {
        if (n?.object as AnyObject?) === viewer {
            self.setThumbnailsView(nil, viewer: nil)
        }
    }

    @objc(setThumbnailsView:viewer:)
    public func setThumbnailsView(_ list: NSView?, viewer v: ViewerController?) {
        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") == false {
            return
        }

        if associatedScreen == nil { associatedScreen = NSMutableDictionary() }


        var tb = list
        if UserDefaults.standard.bool(forKey: "SeriesListVisible") == false {
            tb = nil
        }

        do {
            try HorosObjCException.perform {
                if tb === self.thumbnailsView {
                    if let v = v, tb != nil, (v.window?.windowNumber ?? 0) > 0 {
                        self.window?.order(.above, relativeTo: v.window?.windowNumber ?? 0)
                    }

                    if let tb = tb {
                        if (associatedScreen?.object(forKey: pointerKey(tb)) as AnyObject?) !== (self.window?.screen as AnyObject?) {
                            if let screen = self.window?.screen {
                                associatedScreen?.setObject(screen, forKey: pointerKey(tb))
                            } else {
                                associatedScreen?.removeObject(forKey: pointerKey(tb))
                            }
                        }
                    } else {
                        if self.window?.isVisible == true {
                            self.window?.orderOut(self)
                        }
                    }

                    return
                }

                self.viewer = v

                if self.thumbnailsView !== tb {
                    // -addSubview: with nil does nothing, as the former message did.
                    if let superView = self.superView, let previous = self.thumbnailsView {
                        superView.addSubview(previous)
                    }

                    self.thumbnailsView = tb

                    self.superView = self.thumbnailsView?.superview

                    if let borrowed = self.thumbnailsView {
                        self.window?.contentView?.addSubview(borrowed)
                        borrowed.isHidden = false
                        borrowed.setFrameSize(borrowed.superview?.frame.size ?? NSZeroSize)
                    }
                }

                if let borrowed = self.thumbnailsView {
                    do {
                        try HorosObjCException.perform {
                            if (associatedScreen?.object(forKey: pointerKey(borrowed)) as AnyObject?) !== (self.window?.screen as AnyObject?) {
                                if let screen = self.window?.screen {
                                    associatedScreen?.setObject(screen, forKey: pointerKey(borrowed))
                                } else {
                                    associatedScreen?.removeObject(forKey: pointerKey(borrowed))
                                }
                            }

                            if self.viewer?.window?.isKeyWindow == true {
                                self.window?.orderBack(self)
                            }
                        }
                    } catch {
                        if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                            _N2LogExceptionImpl(exception, false, "-[ThumbnailsListPanel setThumbnailsView:viewer:]")
                        }
                    }
                } else {
                    if self.window?.isVisible == true {
                        self.window?.orderOut(self)
                    }
                }

                if self.thumbnailsView != nil, let viewer = self.viewer {
                    self.applicationDidChangeScreenParameters(nil)

                    if viewer.window?.isKeyWindow == true {
                        self.window?.order(.above, relativeTo: viewer.window?.windowNumber ?? 0)
                    }
                }
            }
        } catch {
            if let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(exception, false, "-[ThumbnailsListPanel setThumbnailsView:viewer:]")
            }
        }
    }
}
