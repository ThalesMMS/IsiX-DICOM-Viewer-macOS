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
//
// KFSplitView.m
// KFSplitView v. 1.3, 11/27/2004
// 
// Copyright (c) 2003-2004 Ken Ferry. Some rights reserved.
// http://homepage.mac.com/kenferry/software.html
//
// Other contributors: Kirk Baker, John Pannell
// 
// This work is licensed under a Creative Commons license:
// http://creativecommons.org/licenses/by-nc/1.0/
//
// Send me an email if you have any problems (after you've read what there is to read).
//
// You can reach me at kenferry at the domain mac.com.
// 
// On this whole major axis, minor axis thing:
// 
//     The 'major' axis refers to the direction in which dividers can move.
//     It's the y-axis when [self isVertical] returns NO, and the x-axis otherwise.
//     Pretty much everything that uses coordinates or dimensions in this file works
//     more comfortably in that coordinate system.
// 
// Other
// 
//     This class is a basically a complete reimplementation of NSSplitView.  The
//     underlying NSSplitView is mostly used for drawing dividers.

import AppKit

// KFSplitView is implemented in Swift since #714. The Objective-C name, the
// selectors and <Horos/KFSplitView.h> are those of the former class; the header
// still declares the KFSplitViewDelegate informal protocol and the notification
// names, whose constants stay in Notifications.m. The exported KFOffScreenPoint
// global stays in KFSplitView+CAPI.m, with kfScaleUInts, which draws from
// rand(), unavailable to Swift.
//
// The arithmetic keeps the former types: coordinates are float, subview
// thicknesses unsigned int, divider indexes int, with C's conversions between
// them, so that frames and saved positions come out the same.

/// Where a collapsed subview is moved; the value of KFOffScreenPoint.
private let kfOffScreenPoint = NSPoint(x: 1000000.0, y: 1000000.0)

/// Position autosave names in use by any KFSplitView (the former file-level set).
private let kfInUsePositionNames = NSMutableSet()

private let savedPositionVersionKey = "version"
private let savedPositionSubviewsKey = "subviews"
private let savedPositionSubviewFrameKey = "frame"
private let savedPositionSubviewIsCollapsedKey = "collapsed"
private let savedPositionIsVerticalKey = "isVertical"

/// The delegate methods of the KFSplitViewDelegate informal protocol, sent by
/// their Objective-C selectors to whatever object is the delegate.
@objc private protocol KFSplitViewDelegateMessages {
    @objc(splitView:didDoubleClickInDivider:)
    optional func splitView(_ sender: Any, didDoubleClickInDivider index: Int32)
    @objc(splitView:didFinishDragInDivider:)
    optional func splitView(_ sender: Any, didFinishDragInDivider index: Int32)
}

/// C's conversion of a double to unsigned int, as arm64 does it: truncation,
/// saturating at 0 and UINT_MAX, NaN giving 0.
private func kfUnsigned(_ value: Double) -> UInt32 {
    if value.isNaN || value <= 0 { return 0 }
    if value >= Double(UInt32.max) { return UInt32.max }
    return UInt32(value)
}

@objc(KFSplitView)
public final class KFSplitView: NSSplitView {
    // The former instance variables. Each is nil until -kfSetup, as the
    // Objective-C ivars were while NSSplitView's initializer ran.

    // retained
    private var kfCollapsedSubviews: NSMutableSet?
    private var kfDividerRects: NSMutableArray?
    private var kfPositionAutosaveName: String?
    private var kfIsVerticalResizeCursor: NSCursor?
    private var kfNotIsVerticalResizeCursor: NSCursor?

    // not retained: the cursor is one of the two above, the defaults and the
    // notification center are the shared ones.
    private var kfCurrentResizeCursor: NSCursor?
    private var kfDefaults: UserDefaults?
    private var kfNotificationCenter: NotificationCenter?
    private var kfIsVertical = false
    /// Not retained, as before. Weak: the delegate clears itself in the app
    /// (OrthogonalMPRPETCTViewer), and a delegate freed without doing so now
    /// reads as nil instead of a dangling pointer.
    private weak var kfDelegate: NSSplitViewDelegate?

    // MARK: Utility

    // The former macros: coordinates along the major and minor axes.
    private func majorCoord(_ point: NSPoint) -> CGFloat { kfIsVertical ? point.x : point.y }
    private func minorCoord(_ point: NSPoint) -> CGFloat { kfIsVertical ? point.y : point.x }
    private func majorDim(_ size: NSSize) -> CGFloat { kfIsVertical ? size.width : size.height }
    private func minorDim(_ size: NSSize) -> CGFloat { kfIsVertical ? size.height : size.width }
    private func point(major: CGFloat, minor: CGFloat) -> NSPoint {
        kfIsVertical ? NSPoint(x: major, y: minor) : NSPoint(x: minor, y: major)
    }
    private func size(major: CGFloat, minor: CGFloat) -> NSSize {
        kfIsVertical ? NSSize(width: major, height: minor) : NSSize(width: minor, height: major)
    }

    private func dividerRect(at index: Int) -> NSRect {
        (kfDividerRects?.object(at: index) as? NSValue)?.rectValue ?? .zero
    }

    private var delegateMessages: KFSplitViewDelegateMessages? {
        kfDelegate.map { unsafeBitCast($0 as AnyObject, to: KFSplitViewDelegateMessages.self) }
    }

    // MARK: Setup/teardown

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        kfSetup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        kfSetup()
    }

    @objc(kfSetup)
    func kfSetup() {
        // be sure to setup cursors before calling setVertical:
        kfSetupResizeCursors()

        kfCollapsedSubviews = NSMutableSet()
        kfDividerRects = NSMutableArray()

        kfDefaults = UserDefaults.standard
        kfNotificationCenter = NotificationCenter.default

        let isVertical = self.isVertical
        self.isVertical = isVertical

        // This class places its subviews by frame, with its own adjustSubviews
        // and divider tracking. Left as NSSplitView's arranged views, in an
        // Auto Layout window they carried no autoresizing constraints, only
        // NSSplitView's own size constraints (NSSplitView.PreferredSize and
        // .FallbackSize) at the sizes they had in the nib, which nothing here
        // updates. Every layout pass put the panes back to those sizes: the
        // rows of the PET-CT fusion window stopped following the window and
        // their dividers, and each row undid the frames the viewer copied into
        // it from the others (#806). As plain subviews they translate their
        // frames into constraints, and the frames set here hold.
        arrangesAllSubviews = false
        for view in arrangedSubviews { removeArrangedSubview(view) }
    }

    // Attempts to find cursors to use as kfIsVerticalResizeCursor and kfNotIsVerticalResizeCursor.
    // If no good cursors can be found, an error is printed and the arrow cursor is used.
    @objc(kfSetupResizeCursors)
    func kfSetupResizeCursors() {
        // standard Jaguar NSSplitView resize cursor
        let isVerticalImage = NSImage(named: "NSTruthHorizontalResizeCursor") ?? NSImage(named: "NSTruthHResizeCursor")
        if let isVerticalImage {
            kfIsVerticalResizeCursor = NSCursor(image: isVerticalImage, hotSpot: NSPoint(x: 8, y: 8))
        }

        // standard Jaguar NSSplitView resize cursor
        let isNotVerticalImage = NSImage(named: "NSTruthVerticalResizeCursor") ?? NSImage(named: "NSTruthVResizeCursor")
        if let isNotVerticalImage {
            kfNotIsVerticalResizeCursor = NSCursor(image: isNotVerticalImage, hotSpot: NSPoint(x: 8, y: 8))
        }

        if kfIsVerticalResizeCursor == nil {
            kfIsVerticalResizeCursor = NSCursor.arrow
            NSLog("Warning - no horizontal resizing cursor located.  Please report this as a bug.")
        }
        if kfNotIsVerticalResizeCursor == nil {
            kfNotIsVerticalResizeCursor = NSCursor.arrow
            NSLog("Warning - no vertical resizing cursor located.  Please report this as a bug.")
        }
    }

    // The former class did not call super.
    public override func awakeFromNib() {
        kfRecalculateDividerRects()
    }

    deinit {
        kfSetDelegate(nil)
        _ = setPositionAutosaveName("")
    }

    // MARK: Main processing

    public override func mouseDown(with event: NSEvent) {
        var theEvent = event
        // All coordinates are major axis coordinates unless otherwise specified.  See the top of the file
        // for an explanation of major and minor axes.

        // setup
        let minorDim = Float(self.minorDim(frame.size))    // common dimension of all subviews
        let dividerThickness = Float(self.dividerThickness)
        let distantFuture = Date.distantFuture

        // PRECOMPUTATION - we do as much as we can before starting the event loop.

        // figure out which divider is being dragged
        var mouseCoord = Float(majorCoord(convert(theEvent.locationInWindow, from: nil)))
        // An int, as before: NSNotFound comes back as -1, which the test below
        // does not catch.
        let divider = Int(kfGetDividerAtMajCoord(mouseCoord))
        if divider == NSNotFound {
            return
        }

        // if the event is a double click we let the delegate deal with it
        // (with -1 when no divider is under the mouse, as before)
        if theEvent.clickCount > 1 {
            if let delegate = kfDelegate,
               delegate.responds(to: #selector(KFSplitViewDelegateMessages.splitView(_:didDoubleClickInDivider:))) {
                delegateMessages?.splitView?(self, didDoubleClickInDivider: Int32(truncatingIfNeeded: divider))
                return
            }
        }

        // No divider under the mouse: the former code went on and raised
        // NSRangeException at -objectAtIndex:-1 below, which AppKit caught and
        // logged. An Objective-C exception must not unwind through Swift.
        if divider < 0 {
            return
        }

        // firstSubview is the subview above (left) of the divider
        // secondSubview is the subview below (right) of the divider
        let subviews = self.subviews as NSArray
        let firstSubview = subviews.object(at: divider) as! NSView
        let secondSubview = subviews.object(at: divider + 1) as! NSView

        // set firstSubviewMinCoord and secondSubviewMaxCoord.  Here's a little diagram:
        //     ------------ <- firstSubviewMinCoord
        //
        //
        //
        //
        //     ------------ <- dividerCoord (not set yet)
        //     ------------
        //
        //
        //     ------------ <- secondSubviewMaxCoord
        let firstSubviewMinCoord: Float
        let secondSubviewMaxCoord: Float
        if !isSubviewCollapsed(firstSubview) {
            firstSubviewMinCoord = Float(majorCoord(firstSubview.frame.origin))
        } else {
            firstSubviewMinCoord = Float(majorCoord(dividerRect(at: divider).origin))
        }
        if !isSubviewCollapsed(secondSubview) {
            secondSubviewMaxCoord = Float(majorCoord(secondSubview.frame.origin) + majorDim(secondSubview.frame.size))
        } else {
            secondSubviewMaxCoord = Float(majorCoord(dividerRect(at: divider).origin) + CGFloat(dividerThickness))
        }

        // hardMinCoord and hardMaxCoord are the absolute minimum and maximum values that may be
        // assigned to dividerCoord. delMinCoord and delMaxCoord are minimum and maximum values
        // for dividerCoord that are supplied by the delegate. These last are _not_ absolute: if the
        // delegate allows collapsing of subviews then dividerCoord can snap from delMinCoord to
        // hardMinCoord if the user drags the divider more than halfway across the region between them.
        // See Apple's NSSplitView documenation under - splitView:canCollapseSubview:.

        let hardMinCoord = firstSubviewMinCoord
        let hardMaxCoord = secondSubviewMaxCoord - dividerThickness

        var delMinCoord = hardMinCoord
        var delMaxCoord = hardMaxCoord

        if let constrained = kfDelegate?.splitView?(self, constrainMinCoordinate: CGFloat(delMinCoord), ofSubviewAt: divider) {
            delMinCoord = Float(constrained)
        }
        if let constrained = kfDelegate?.splitView?(self, constrainMaxCoordinate: CGFloat(delMaxCoord), ofSubviewAt: divider) {
            delMaxCoord = Float(constrained)
        }

        delMinCoord = (delMinCoord < hardMinCoord) ? hardMinCoord : delMinCoord
        delMaxCoord = (delMaxCoord > hardMaxCoord) ? hardMaxCoord : delMaxCoord

        if delMinCoord > delMaxCoord {
            // this follows apple's implementation.  It says that if the delegate does
            // not supply any zone where the divider can sit without collapsing a subview then
            // ignore the delegate.  The other option would be to always collapse to one subview
            // or the other, if one or both of the subviews are collasible.  That could be a bit of a UI
            // problem, because the user could try to drag a subview and have nothing happen.
            delMinCoord = hardMinCoord
            delMaxCoord = hardMaxCoord
        }

        var firstSubviewCanCollapse = false
        var secondSubviewCanCollapse = false
        if let delegate = kfDelegate, delegate.responds(to: #selector(NSSplitViewDelegate.splitView(_:canCollapseSubview:))) {
            firstSubviewCanCollapse = delegate.splitView?(self, canCollapseSubview: firstSubview) ?? false
            secondSubviewCanCollapse = delegate.splitView?(self, canCollapseSubview: secondSubview) ?? false
        }

        // When the user grabs and drags the divider he holds onto that
        // particular spot while dragging.
        // mouseToDividerOffset is the difference between dividerCoord (the top of
        // the divider) and mouseCoord.
        let mouseToDividerOffset = Float(majorCoord(dividerRect(at: divider).origin) - CGFloat(mouseCoord))

        // EVENT-LOOP
        var prevDividerCoord: Float = 1000000 // something non-sensical
        repeat {
            mouseCoord = Float(majorCoord(convert(theEvent.locationInWindow, from: nil)))
            var dividerCoord = mouseCoord + mouseToDividerOffset
            // The delegate may constrain the possible values for dividerCoord.
            // The former code called it through a variadic float function
            // pointer; this is the delegate method as NSSplitView declares it.
            if let constrained = kfDelegate?.splitView?(self, constrainSplitPosition: CGFloat(dividerCoord), ofSubviewAt: divider) {
                dividerCoord = Float(constrained)
            }

            // There are five regions where user may have dragged the divider:
            //     collapse first subview
            //     stick the divider to delMinCoord
            //     move freely
            //     stick the divider to delMaxCoord
            //     collapse the second subview
            if hardMinCoord == hardMaxCoord {
                // special case: divider is pinned.  It is possible to collapse both subviews.
                setSubview(firstSubview, isCollapsed: firstSubviewCanCollapse)
                setSubview(secondSubview, isCollapsed: secondSubviewCanCollapse)
                dividerCoord = hardMinCoord
            } else if firstSubviewCanCollapse && dividerCoord < hardMinCoord + (delMinCoord - hardMinCoord) / 2 {
                // collapse first subview
                setSubview(secondSubview, isCollapsed: false)
                setSubview(firstSubview, isCollapsed: true)
                dividerCoord = hardMinCoord
            } else if dividerCoord < delMinCoord {
                // stick to delMinCoord
                setSubview(firstSubview, isCollapsed: false)
                setSubview(secondSubview, isCollapsed: false)
                dividerCoord = delMinCoord
            } else if dividerCoord < delMaxCoord {
                // move freely
                setSubview(firstSubview, isCollapsed: false)
                setSubview(secondSubview, isCollapsed: false)
            } else if !secondSubviewCanCollapse || dividerCoord < hardMaxCoord - (hardMaxCoord - delMaxCoord) / 2 {
                // stick to delMaxCoord
                setSubview(firstSubview, isCollapsed: false)
                setSubview(secondSubview, isCollapsed: false)
                dividerCoord = delMaxCoord
            } else {
                // collapse second subview
                setSubview(firstSubview, isCollapsed: false)
                setSubview(secondSubview, isCollapsed: true)
                dividerCoord = hardMaxCoord
            }

            if prevDividerCoord != dividerCoord {
                // Position and resize elements.  A collapsing subview's frame size doesn't change,
                // the subview just gets moved way offscreen (as in NSSplitView).
                // The diagram may help:
                //
                //     ------------ <- firstSubviewMinCoord
                //
                //
                //
                //     ------------ <- dividerCoord
                //     ------------ <- dividerCoord + dividerThickness
                //
                //
                //     ------------ <- secondSubviewMaxCoord

                kfNotificationCenter?.post(name: NSSplitView.willResizeSubviewsNotification, object: self)

                // divider
                kfPutDivider(Int32(truncatingIfNeeded: divider), atMajCoord: dividerCoord)

                // firstSubview
                if !isSubviewCollapsed(firstSubview) {
                    let newFrame = NSRect(origin: point(major: CGFloat(firstSubviewMinCoord), minor: 0),
                                          size: size(major: CGFloat(dividerCoord - firstSubviewMinCoord), minor: CGFloat(minorDim)))

                    if !NSEqualRects(firstSubview.frame, newFrame) {
                        firstSubview.frame = newFrame
                        firstSubview.needsDisplay = true
                    }
                } else {
                    firstSubview.setFrameOrigin(kfOffScreenPoint)
                }

                // secondSubview
                if !isSubviewCollapsed(secondSubview) {
                    let newFrame = NSRect(origin: point(major: CGFloat(dividerCoord + dividerThickness), minor: 0),
                                          size: size(major: CGFloat(secondSubviewMaxCoord - (dividerCoord + dividerThickness)), minor: CGFloat(minorDim)))

                    if !NSEqualRects(secondSubview.frame, newFrame) {
                        secondSubview.frame = newFrame
                        secondSubview.needsDisplay = true
                    }
                } else {
                    secondSubview.setFrameOrigin(kfOffScreenPoint)
                }

                kfNotificationCenter?.post(name: NSSplitView.didResizeSubviewsNotification, object: self)

                prevDividerCoord = dividerCoord
            }

            // get the next relevant event
            guard let next = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp],
                                             until: distantFuture,
                                             inMode: .eventTracking,
                                             dequeue: true) else { break }
            theEvent = next
        } while theEvent.type == .leftMouseDragged

        // inform delegate that user has finished dragging divider
        if let delegate = kfDelegate,
           delegate.responds(to: #selector(KFSplitViewDelegateMessages.splitView(_:didFinishDragInDivider:))) {
            delegateMessages?.splitView?(self, didFinishDragInDivider: Int32(truncatingIfNeeded: divider))
        }
    }

    // Call this method to retile the subviews, not adjustSubviews.
    // It 1) dispatches will and did resize subviews notifications
    //    2) calls the appropriate method to do the retiling.  That's a method of
    //       the delegate if it has one and the default adjustSubviews otherwise.
    //    3) cleans up some other layout, like divider positions
    public override func resizeSubviews(withOldSize oldBoundsSize: NSSize) {
        NSDisableScreenUpdates()

        kfNotificationCenter?.post(name: NSSplitView.willResizeSubviewsNotification, object: self)

        if let delegate = kfDelegate, delegate.responds(to: #selector(NSSplitViewDelegate.splitView(_:resizeSubviewsWithOldSize:))) {
            delegate.splitView?(self, resizeSubviewsWithOldSize: oldBoundsSize)
        } else {
            adjustSubviews()
        }

        kfRecalculateDividerRects()
        kfMoveCollapsedSubviewsOffScreen()

        kfNotificationCenter?.post(name: NSSplitView.didResizeSubviewsNotification, object: self)

        NSEnableScreenUpdates()
    }

    // See Apple's NSSplitView docs.  However, note that in general you want to call
    // resizeSubviewsWithOldSize:, not this method.  The exception is that you might
    // want to call adjustSubviews from splitView:resizeSubviewsWithOldSize: in the
    // the delegate
    public override func adjustSubviews() {
        // The 'thickness' of a subview will mean the amount of space along
        // the major axis that the subview occupies in the splitview.
        // We work in integral values, though actual thicknesses are floats.
        // In the current OS, the floats actually have integral values.
        //
        // Ex 1: The thickness of a collapsed subview is 0.
        // Ex 2: For an uncollapsed subview in a horizontal (standard direction) splitview,
        //       thickness means height.

        // setup
        let subviews = self.subviews
        let numSubviews = Int32(truncatingIfNeeded: subviews.count)
        if numSubviews == 0 {
            return
        }

        let subviewThicknesses = UnsafeMutablePointer<UInt32>.allocate(capacity: Int(numSubviews))
        defer { subviewThicknesses.deallocate() }

        // Fill out subviewThicknesses array.
        // Also keep track of the total thickness of all subviews, and
        // of the first expanded subview
        var totalSubviewThicknesses: UInt32 = 0
        var firstExpandedSubviewIndex = NSNotFound
        for i in 0..<Int(numSubviews) {
            let subview = subviews[i]
            if !isSubviewCollapsed(subview) {
                subviewThicknesses[i] = kfUnsigned(floor(Double(majorDim(subview.frame.size))))
                totalSubviewThicknesses &+= subviewThicknesses[i]
                if firstExpandedSubviewIndex == NSNotFound { firstExpandedSubviewIndex = i }
            } else {
                subviewThicknesses[i] = 0
            }
        }

        // Compute new thicknesses for subviews.

        // In the end, the subview thicknesses should sum to the thickness of the splitview minus the space occupied by dividers.
        // KFMAX(a, b): a > b ? a : b.
        let available = floor(Double(majorDim(frame.size) - dividerThickness * CGFloat(numSubviews - 1)))
        let targetTotalSubviewsThickness = kfUnsigned(available > 0 ? available : 0)

        // If at least one of the subviews has positive thickness
        if totalSubviewThicknesses != 0 {
            // then we can scale all the thicknesses
            KFSplitViewScaleUInts(subviewThicknesses, numSubviews, targetTotalSubviewsThickness)
        } else { // otherwise we'll have to expand one of the subviews to fill the entire space
            if firstExpandedSubviewIndex != NSNotFound {
                subviewThicknesses[firstExpandedSubviewIndex] = targetTotalSubviewsThickness
            } else {
                subviewThicknesses[0] = targetTotalSubviewsThickness
            }
        }

        // layout subviews
        kfLayoutSubviews(usingThicknesses: subviewThicknesses)
    }

    // Required: Sum of all subviewThicknesses <= splitViewThickness - dividersThickness.
    // If the splitview has positive available space for subviews, then one of the supplied subview thicknesses
    // must also be positive.  Extra space will be dumped into the last subview with positive thickness.
    // See adjustSubviews for the definition of 'thickness'.
    //
    // Does not currently put collapsed subviews off screen or do divider placement.
    // Could be done efficiently here, but would duplicate functionality of other methods.
    @objc(kfLayoutSubviewsUsingThicknesses:)
    func kfLayoutSubviews(usingThicknesses subviewThicknesses: UnsafeMutablePointer<UInt32>) {
        // setup
        let subviews = self.subviews
        let numSubviews = subviews.count
        let minorDimOfSplitViewSize = Float(minorDim(frame.size))
        let dividerThickness = Float(self.dividerThickness)

        // Compute lastPositiveThicknessSubviewIndex.
        var lastPositiveThicknessSubviewIndex = NSNotFound
        var i = numSubviews - 1
        while i >= 0 {
            if subviewThicknesses[i] != 0 {
                lastPositiveThicknessSubviewIndex = i
                break
            }
            i -= 1
        }

        // We walk down the major axis, setting subview frames as we go.
        var curMajAxisPos: Float = 0
        for i in 0..<numSubviews {
            let subview = subviews[i]

            var newSubviewThickness: Float = -1 // sentinel value, meaning "do not change"

            if subviewThicknesses[i] == 0 { // If subview should have no thickness
                // then shrink its frame if it is uncollapsed.
                if !isSubviewCollapsed(subview) {
                    newSubviewThickness = 0
                }
            } else { // If supplied thickness is positive
                // make sure the subview isn't collapsed.
                if isSubviewCollapsed(subview) {
                    setSubview(subview, isCollapsed: false)
                }

                // If this is the last subview that we're going to give a positive thickness
                if i == lastPositiveThicknessSubviewIndex {
                    // we overrule the given the given value and just fill all available area.
                    let remainingDividersThickness = Float(numSubviews - 1 - i) * dividerThickness
                    let splitViewThickness = Float(majorDim(frame.size))

                    let remaining = splitViewThickness - curMajAxisPos - remainingDividersThickness
                    newSubviewThickness = remaining > 0 ? remaining : 0
                } else { // If this isn't the last subview that we're going to set to a positive thickness
                    // use the supplied thickness.
                    newSubviewThickness = Float(subviewThicknesses[i])
                }
            }

            // If we found a new subview thickness
            if newSubviewThickness != -1 {
                // set the subview's frame accordingly
                let newSubviewOrigin = point(major: CGFloat(curMajAxisPos), minor: 0)
                let newSubviewSize = size(major: CGFloat(newSubviewThickness), minor: CGFloat(minorDimOfSplitViewSize))
                let newFrame = NSRect(x: newSubviewOrigin.x, y: newSubviewOrigin.y,
                                      width: newSubviewSize.width, height: newSubviewSize.height)

                if !NSEqualRects(subview.frame, newFrame) {
                    subview.frame = newFrame
                    subview.needsDisplay = true
                }

                // and advance down the major axis.
                curMajAxisPos += newSubviewThickness
            }

            // Account for divider thickness.
            if i < numSubviews - 1 {
                curMajAxisPos += dividerThickness
            }
        }
    }

    @objc(kfMoveCollapsedSubviewsOffScreen)
    func kfMoveCollapsedSubviewsOffScreen() {
        guard let collapsed = kfCollapsedSubviews else { return }
        for case let subview as NSView in collapsed {
            subview.setFrameOrigin(kfOffScreenPoint)
        }
    }

    // The former class did not call super.
    public override func draw(_ rect: NSRect) {
        let numDividers = kfDividerRects?.count ?? 0
        for i in 0..<numDividers {
            drawDivider(in: dividerRect(at: i))
        }
    }

    // returns the index ('offset' in Apple's docs) of the divider under the
    // given coordinate, or NSNotFound if there isn't a divider there.
    // An int, as before: NSNotFound is truncated to -1.
    @objc(kfGetDividerAtMajCoord:)
    func kfGetDividerAtMajCoord(_ coord: Float) -> Int32 {
        let numDividers = kfDividerRects?.count ?? 0
        var result = NSNotFound
        let dividerThickness = Float(self.dividerThickness)

        for i in 0..<numDividers {
            let curDividerMinimumMajorCoord = Float(majorCoord(dividerRect(at: i).origin))
            if curDividerMinimumMajorCoord <= coord && coord < curDividerMinimumMajorCoord + dividerThickness {
                result = i
                break
            }
        }

        return Int32(truncatingIfNeeded: result)
    }

    @objc(kfPutDivider:atMajCoord:)
    func kfPutDivider(_ offset: Int32, atMajCoord coord: Float) {
        // Before -kfSetup there is no list: the former loop below would not end.
        guard let dividerRects = kfDividerRects else { return }

        while UInt(dividerRects.count) <= UInt(bitPattern: Int(offset)) {
            dividerRects.add(NSValue(rect: .zero))
        }

        let newOrigin = point(major: CGFloat(coord), minor: 0)
        let newSize = size(major: dividerThickness, minor: minorDim(frame.size))
        let newFrame = NSRect(x: newOrigin.x, y: newOrigin.y, width: newSize.width, height: newSize.height)

        if !NSEqualRects(dividerRect(at: Int(offset)), newFrame) {
            dividerRects.replaceObject(at: Int(offset), with: NSValue(rect: newFrame))
            setNeedsDisplay(newFrame)
            let subviews = self.subviews as NSArray
            (subviews.object(at: Int(offset)) as! NSView).needsDisplay = true
            (subviews.object(at: Int(offset) + 1) as! NSView).needsDisplay = true
        }
    }

    // positions all dividers based on the current location of the subviews
    @objc(kfRecalculateDividerRects)
    public func kfRecalculateDividerRects() {
        let dividerThickness = Float(self.dividerThickness)
        let subviews = self.subviews
        let numSubviews = Int32(truncatingIfNeeded: subviews.count)

        var curMajAxisPos: Float = 0
        var i: Int32 = 0
        while i < numSubviews - 1 {
            let subview = subviews[Int(i)]
            if !isSubviewCollapsed(subview) {
                curMajAxisPos = Float(CGFloat(curMajAxisPos) + majorDim(subview.frame.size))
            }

            kfPutDivider(i, atMajCoord: curMajAxisPos)
            curMajAxisPos += dividerThickness
            i += 1
        }

        if let dividerRects = kfDividerRects {
            let numDividerRects = Int32(truncatingIfNeeded: dividerRects.count)
            // With no subview, the former code asked for the range {-1, n+1}
            // and raised NSRangeException, which AppKit caught and logged.
            if numDividerRects > numSubviews - 1 && numSubviews > 0 {
                dividerRects.removeObjects(in: NSRange(location: Int(numSubviews - 1),
                                                       length: Int(numDividerRects - numSubviews + 1)))
            }
        }

        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        let numDividers = kfDividerRects?.count ?? 0
        guard let cursor = kfCurrentResizeCursor else { return }
        for i in 0..<numDividers {
            addCursorRect(dividerRect(at: i), cursor: cursor)
        }
    }

    // MARK: Accessors

    public override var isVertical: Bool {
        get { super.isVertical }
        set {
            super.isVertical = newValue
            kfIsVertical = newValue
            if kfIsVertical {
                kfCurrentResizeCursor = kfIsVerticalResizeCursor
            } else {
                kfCurrentResizeCursor = kfNotIsVerticalResizeCursor
            }
        }
    }

    // automatically registers the delegate for relevant notifications, and unregisters
    // the old delegate for those same notifications. NSSplitView's own delegate
    // stays unset, as before.
    public override weak var delegate: NSSplitViewDelegate? {
        get { kfDelegate }
        set { kfSetDelegate(newValue) }
    }

    private func kfSetDelegate(_ delegate: NSSplitViewDelegate?) {
        let delegateAutoRegNotifications: [NSNotification.Name] = [
            NSSplitView.willResizeSubviewsNotification,
            NSSplitView.didResizeSubviewsNotification,
            .KFSplitViewDidCollapseSubview,
            .KFSplitViewDidExpandSubview]
        let delegateMethodNames = [
            "splitViewWillResizeSubviews:",
            "splitViewDidResizeSubviews:",
            "splitViewDidCollapseSubview:",
            "splitViewDidExpandSubview:"]

        if let old = kfDelegate {
            for name in delegateAutoRegNotifications {
                kfNotificationCenter?.removeObserver(old, name: name, object: self)
            }
        }

        kfDelegate = delegate

        if let new = kfDelegate {
            for (name, methodName) in zip(delegateAutoRegNotifications, delegateMethodNames) {
                let methodSelector = NSSelectorFromString(methodName)
                if new.responds(to: methodSelector) {
                    kfNotificationCenter?.addObserver(new, selector: methodSelector, name: name, object: self)
                }
            }
        }
    }

    public override func isSubviewCollapsed(_ subview: NSView) -> Bool {
        kfCollapsedSubviews?.contains(subview) ?? false
    }

    // sets the collapse-state of a subview, which is completely independent
    // of that subview's frame (as in NSSplitView).  (Sometime) after calling this
    // you'll need to tell the splitview to resize its subviews.
    // Normally, that would be this call:
    //    [kfSplitView resizeSubviewsWithOldSize:[kfSplitView bounds].size];
    @objc(setSubview:isCollapsed:)
    public func setSubview(_ subview: NSView, isCollapsed flag: Bool) {
        if flag != isSubviewCollapsed(subview) {
            let subviewDictionary: [AnyHashable: Any] = ["subview": subview]
            if flag {
                kfCollapsedSubviews?.add(subview)
                kfNotificationCenter?.post(name: .KFSplitViewDidCollapseSubview,
                                           object: self,
                                           userInfo: subviewDictionary)
            } else {
                kfCollapsedSubviews?.remove(subview)
                kfNotificationCenter?.post(name: .KFSplitViewDidExpandSubview,
                                           object: self,
                                           userInfo: subviewDictionary)
            }
        }
    }

    // MARK: Position saving

    // FOR DOCUMENTATION OF POSITION SAVING METHODS SEE APPLE'S NSWINDOW DOCS

    @objc(removePositionUsingName:)
    public class func removePosition(usingName name: String) {
        UserDefaults.standard.removeObject(forKey: kfDefaultsKey(forName: name))
    }

    @objc(savePositionUsingName:)
    public func savePosition(usingName name: String) {
        let key = KFSplitView.kfDefaultsKey(forName: name)
        let prop = plistObjectWithSavedPosition()
        kfDefaults?.set(prop, forKey: key)
    }

    @objc(setPositionUsingName:)
    @discardableResult
    public func setPosition(usingName name: String) -> Bool {
        if let object = kfDefaults?.object(forKey: KFSplitView.kfDefaultsKey(forName: name)) {
            setPosition(fromPlistObject: object)
            return true
        }
        return false
    }

    @objc(setPositionAutosaveName:)
    @discardableResult
    public func setPositionAutosaveName(_ name: String?) -> Bool {
        var name = name
        if name == "" {
            name = nil
        }

        if let name, kfInUsePositionNames.contains(name) {
            return false
        }

        if let old = kfPositionAutosaveName {
            kfInUsePositionNames.remove(old)
        }

        kfPositionAutosaveName = name
        if let name {
            setPosition(usingName: name)
            kfInUsePositionNames.add(name)
            kfNotificationCenter?.addObserver(self,
                                              selector: #selector(kfSavePositionUsingAutosaveName(_:)),
                                              name: NSSplitView.didResizeSubviewsNotification,
                                              object: self)
        } else {
            kfNotificationCenter?.removeObserver(self,
                                                 name: NSSplitView.didResizeSubviewsNotification,
                                                 object: self)
        }

        return true
    }

    @objc(positionAutosaveName)
    public func positionAutosaveName() -> String? {
        kfPositionAutosaveName
    }

    @objc(setPositionFromPlistObject:)
    public func setPosition(fromPlistObject plistObject: Any?) {
        if let positionDict = plistObject as? NSDictionary {
            // check position data format version
            if ((positionDict.object(forKey: savedPositionVersionKey) as AnyObject?)?.intValue ?? 0) == 2 {
                // set subview positions
                let subviews = self.subviews
                let numSubviews = subviews.count
                let subviewPositionsArray = positionDict.object(forKey: savedPositionSubviewsKey) as? NSArray

                // what if the number of saved subview records and the actual number of subviews don't match?
                // we'll set positions until we run out of either subviews or data records
                let numSavedSubviews = subviewPositionsArray?.count ?? 0
                let numSettableSubviews = min(numSubviews, numSavedSubviews)

                for i in 0..<numSettableSubviews {
                    let subview = subviews[i]
                    let subviewPositionData = subviewPositionsArray?.object(at: i) as? NSDictionary

                    // subview data consists of frame and collapse state
                    subview.frame = NSRectFromString(subviewPositionData?.object(forKey: savedPositionSubviewFrameKey) as? String ?? "")
                    setSubview(subview, isCollapsed: (subviewPositionData?.object(forKey: savedPositionSubviewIsCollapsedKey) as AnyObject?)?.boolValue ?? false)
                }

                // set isVertical
                self.isVertical = (positionDict.object(forKey: savedPositionIsVerticalKey) as AnyObject?)?.boolValue ?? false
            }
        }

        resizeSubviews(withOldSize: bounds.size)
    }

    @objc(plistObjectWithSavedPosition)
    public func plistObjectWithSavedPosition() -> Any {
        let positionDict = NSMutableDictionary()

        // save position data format version
        positionDict.setObject(NSNumber(value: Int32(2)), forKey: savedPositionVersionKey as NSString)

        // save subview positions
        let subviewPositionsArray = NSMutableArray()

        for subview in subviews {
            // subview data consists of frame and collapse state
            let subviewPositionData = NSDictionary(
                objects: [NSStringFromRect(subview.frame), NSNumber(value: isSubviewCollapsed(subview))],
                forKeys: [savedPositionSubviewFrameKey as NSString, savedPositionSubviewIsCollapsedKey as NSString])
            subviewPositionsArray.add(subviewPositionData)
        }

        positionDict.setObject(subviewPositionsArray, forKey: savedPositionSubviewsKey as NSString)

        // save isVertical
        positionDict.setObject(NSNumber(value: isVertical), forKey: savedPositionIsVerticalKey as NSString)

        return positionDict
    }

    @objc(kfDefaultsKeyForName:)
    class func kfDefaultsKey(forName name: String) -> String {
        "KFSplitView Position " + name
    }

    @objc(kfSavePositionUsingAutosaveName:)
    func kfSavePositionUsingAutosaveName(_ sender: Any?) {
        // Registered only while there is a name.
        guard let name = kfPositionAutosaveName else { return }
        savePosition(usingName: name)
    }
}
