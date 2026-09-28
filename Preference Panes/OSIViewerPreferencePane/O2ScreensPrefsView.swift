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

/// The former `NSInteger width = bounds.size.width`: truncated toward zero,
/// without trapping where the conversion to NSInteger did not (NaN gives 0,
/// infinities saturate, as on arm64).
private func integerPart(_ value: CGFloat) -> Int {
    if value.isNaN { return 0 }
    if value >= CGFloat(Int.max) { return Int.max }
    if value <= CGFloat(Int.min) { return Int.min }
    return Int(value)
}

/// A screen's thumbnail in O2ScreensPrefsView.
@objc(_O2ScreensPrefsViewScreenRecord)
private final class _O2ScreensPrefsViewScreenRecord: NSObject {
    @objc var frame: NSRect = .zero
    @objc var screen: NSScreen?
}

/// The thumbnails of the screens in the Viewers preference pane, with a menu
/// that picks the screens used for viewers.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors,
/// the xib `customClass` and <Horos/O2ScreensPrefsView.h> are those of the
/// former class.
@objc(O2ScreensPrefsView)
public final class O2ScreensPrefsView: NSControl {
    private let _records = NSMutableArray()
    /// Unretained in the former class; the record is held by _records.
    private weak var _activeRecord: _O2ScreensPrefsViewScreenRecord?

    public override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(observeAppDidChangeScreenParamsNotification(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// The xib instantiates the view with -initWithFrame:; decoding sets up the
    /// same state.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        NotificationCenter.default.addObserver(self, selector: #selector(observeAppDidChangeScreenParamsNotification(_:)), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc(observeAppDidChangeScreenParamsNotification:)
    func observeAppDidChangeScreenParamsNotification(_ n: Notification) {
        _records.removeAllObjects()
        self.needsDisplay = true
    }

    public override func draw(_ refreshframe: NSRect) {
        NSGraphicsContext.current?.saveGraphicsState()

        if _records.count == 0 {
            let screens = NSScreen.screens

            var desktopBounds = screens[0].frame
            for i in stride(from: 1, to: screens.count, by: 1) {
                desktopBounds = NSUnionRect(desktopBounds, screens[i].frame)
            }

            var bounds = self.bounds
            bounds.size.width -= 1; bounds.size.height -= 1
            bounds.size = N2ProportionallyScaleSize(desktopBounds.size, bounds.size)

            let width = CGFloat(integerPart(bounds.size.width)), height = CGFloat(integerPart(bounds.size.height))

            NSColor.black.setStroke()

            for screen in screens {
                let screenFrame = screen.frame
                var frame = NSIntegralRect(NSMakeRect(bounds.origin.x + (screenFrame.origin.x - desktopBounds.origin.x) / desktopBounds.size.width * width,
                                                      bounds.origin.y + (screenFrame.origin.y - desktopBounds.origin.y) / desktopBounds.size.height * height,
                                                      screenFrame.size.width / desktopBounds.size.width * width,
                                                      screenFrame.size.height / desktopBounds.size.height * height))
                frame.origin.x += 0.5; frame.origin.y += 0.5; frame.size.width -= 1; frame.size.height -= 1

                if self.isFlipped {
                    frame = N2FlipRect(frame, bounds)
                }

                let record = _O2ScreensPrefsViewScreenRecord()
                record.screen = screen
                record.frame = frame

                _records.add(record)
            }
        }

        NSGraphicsContext.current?.shouldAntialias = true

        let viewerScreens = (UserDefaults.standard.screensUsedForViewers() ?? []) as NSArray
        let screens = NSScreen.screens
        for phase in 0..<2 {
            for case let record as _O2ScreensPrefsViewScreenRecord in _records {
                if phase == 0 && viewerScreens.contains(record.screen as Any) {
                    continue
                }
                if phase == 1 && !viewerScreens.contains(record.screen as Any) {
                    continue
                }

                NSColor.black.setStroke()

                if viewerScreens.count == 0 {
                    if self.isEnabled {
                        NSColor(deviceRed: 113.0/255, green: 142.0/255, blue: 170.5/255, alpha: 1).setFill()
                    } else {
                        NSColor(deviceWhite: 141.83/255, alpha: 1).setFill()
                    }
                } else if viewerScreens.contains(record.screen as Any) {
                    if self.isEnabled {
                        NSColor(deviceRed: 99.0/255, green: 157.0/255, blue: 214.0/255, alpha: 1).setFill()
                    } else {
                        NSColor(deviceWhite: 156.67/255, alpha: 1).setFill()
                    }
                } else {
                    NSColor.lightGray.setFill()
                }

                var frame = record.frame

                var path = NSBezierPath(rect: frame)
                path.fill(); path.stroke()

                if record.screen === screens[0] {
                    var menuFrame = NSRect.zero
                    NSDivideRect(frame, &menuFrame, &frame, 4, self.isFlipped ? .minY : .maxY)
                    path = NSBezierPath(rect: menuFrame)
                    NSColor.white.setFill()
                    path.fill(); path.stroke()
                }

                if record === _activeRecord {
                    frame.origin.x += 1.5; frame.origin.y += 1.5; frame.size.width -= 3; frame.size.height -= 3
                    path = NSBezierPath(rect: frame)
                    NSColor.gray.setStroke()
                    path.stroke()
                }
            }
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private func recordAtPoint(_ p: NSPoint) -> _O2ScreensPrefsViewScreenRecord? {
        var t: [_O2ScreensPrefsViewScreenRecord] = []
        for case let record as _O2ScreensPrefsViewScreenRecord in _records {
            if NSPointInRect(p, record.frame) {
                t.append(record)
            }
        }

        for s in t {
            if UserDefaults.standard.screenIsUsed(forViewers: s.screen) {
                return s
            }
        }

        if !t.isEmpty {
            return t[0]
        }

        return nil
    }

    @objc(prefersTrackingUntilMouseUp)
    func prefersTrackingUntilMouseUp() -> Bool {
        return true
    }

    public override func rightMouseDown(with theEvent: NSEvent) {
        self.mouseDown(with: theEvent)
    }

    public override func mouseDown(with theEvent: NSEvent) {
        if !self.isEnabled {
            return
        }

        let currentPoint = theEvent.locationInWindow
//      BOOL trackContinously = [self startTrackingAt:currentPoint inView:controlView];

        guard let record = recordAtPoint(self.convert(currentPoint, from: nil)) else {
            return
        }

        _activeRecord = record
        self.display()

        let viewerScreens = (UserDefaults.standard.screensUsedForViewers() ?? []) as NSArray

        let menu = NSMenu(title: "")
        var mi: NSMenuItem

        var name = record.screen?.displayName()
        if name == nil { name = NSLocalizedString("Untitled Display", comment: "") }
        menu.addItem(withTitle: name!, action: nil, keyEquivalent: "")

        menu.addItem(NSMenuItem.separator())

        mi = menu.addItem(withTitle: NSLocalizedString("Use this screen for viewers", comment: ""), action: #selector(_toggleViewersOnScreen(_:)), keyEquivalent: "")
        mi.state = viewerScreens.contains(record.screen as Any) ? .on : .off
        mi.representedObject = record
        mi.target = self

        menu.addItem(NSMenuItem.separator())

        let screens = NSScreen.screens

        if !(viewerScreens.count == screens.count) {
            mi = menu.addItem(withTitle: NSLocalizedString("Use all screens for viewers", comment: ""), action: #selector(_useAllScreensForViewers(_:)), keyEquivalent: "")
            mi.target = self
        }

        if !(viewerScreens.count == 1 && (viewerScreens.object(at: 0) as AnyObject) === screens[0]) {
            mi = menu.addItem(withTitle: NSLocalizedString("Only use the current main screen for viewers", comment: ""), action: #selector(_useMainScreenForViewers(_:)), keyEquivalent: "")
            mi.target = self
        }

        NSMenu.popUpContextMenu(menu, with: theEvent, for: self)

        _activeRecord = nil
        self.display()
    }

//  -(NSString*)toolTip {
//      return NSLocalizedString(@"Click on every screen's thumbnail to enable or disable its usage", nil);
//  }

    @objc(_toggleViewersOnScreen:)
    func _toggleViewersOnScreen(_ mi: NSMenuItem) {
        let record = mi.representedObject as? _O2ScreensPrefsViewScreenRecord
        let ud = UserDefaults.standard
        ud.screen(record?.screen, setIsUsedForViewers: !ud.screenIsUsed(forViewers: record?.screen))
    }

    @objc(_useAllScreensForViewers:)
    func _useAllScreensForViewers(_ mi: NSMenuItem) {
        UserDefaults.standard.set(NSArray(), forKey: O2NonViewerScreensDefaultsKey)
    }

    @objc(_useMainScreenForViewers:)
    func _useMainScreenForViewers(_ mi: NSMenuItem) {
        let screens = NSScreen.screens
        for screen in screens {
            UserDefaults.standard.screen(screen, setIsUsedForViewers: screen === screens[0])
        }
    }
}
