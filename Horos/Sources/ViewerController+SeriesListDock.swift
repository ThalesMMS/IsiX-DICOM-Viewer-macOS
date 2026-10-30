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
import IsiXImaging

// The docked series list of the 2D viewer: its place on an edge of the
// window's split view or in the floating panel, its thickness, shown or
// hidden in step with the other viewers, hidden automatically away from the
// mouse, and the split view's delegate that keeps the dock at the list's
// thickness.

/// Set while a viewer propagates its list's visibility to the other
/// viewers, or re-places its own list. The split view resizes this causes are
/// the app's own, not the user's, and must not be propagated back: another
/// viewer may not be re-placed yet, and answering it would bounce between the
/// two viewers.
nonisolated(unsafe) fileprivate var seriesListResizeInProgress = false

/// Set while a change of SeriesListVisible is passed to the viewers.
nonisolated(unsafe) fileprivate var seriesListVisibleNoReentry = false

// The class does not declare NSSplitViewDelegate in Swift: this file does, so
// that the methods below implement the protocol's (ViewerController.h).
extension ViewerController: NSSplitViewDelegate {}

extension ViewerController {

    /// The stored edge of the list.
    fileprivate var seriesListPlacement: SeriesListPlacement {
        SeriesListLayout.storedPlacement(in: UserDefaults.standard)
    }
}

public extension ViewerController {

    @objc(checkFrameSize)
    func checkFrameSize() -> Bool {
        let visible = matrixIsVisible()

        return visible
    }

    /// How thick the series list strip has to be on the stored edge.
    @objc(horosSeriesListThickness)
    func horosSeriesListThickness() -> CGFloat {
        let placement = seriesListPlacement
        var height = horos_previewMatrix != nil ? horos_previewMatrix!.cellSize.height : 120
        if height < 1 { height = 120 }
        return SeriesListLayout.thickness(for: placement, thumbnailWidth: CGFloat(ThumbnailCell.thumbnailCellWidth()), thumbnailHeight: height)
    }

    @objc(updateSeriesListMode)
    func updateSeriesListMode() {
        guard horos_windowWillClose == false, let splitView = horos_splitView else {
            return
        }

        let wasInProgress = seriesListResizeInProgress
        seriesListResizeInProgress = true

        let floating = UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList")
        let visible = UserDefaults.standard.bool(forKey: "SeriesListVisible")
        let placement = seriesListPlacement
        if let scrollView = horos_previewMatrixScrollView {
            SeriesListLayout.place(scrollView, in: splitView, floating: floating, visible: visible, thumbnailWidth: horosSeriesListThickness(),
                                   placement: placement)
        }
        splitView.resizeSubviews(withOldSize: splitView.bounds.size)
        if visible && horos_needsToBuildSeriesMatrix {
            buildMatrixPreview(false)
        } else if visible, let matrix = horos_previewMatrix {
            SeriesListLayout.layOut(matrix, count: matrix.cells.count, placement: placement, floating: floating)
        }

        seriesListResizeInProgress = wasInProgress
    }

    @objc(setMatrixVisible:)
    func setMatrixVisible(_ visible: Bool) {
        if horos_windowWillClose {
            return
        }

        let currentlyVisible = matrixIsVisible()

        if currentlyVisible != visible {
            // The dock on the stored edge, never the image pane.
            let placement = seriesListPlacement
            let thickness = horosSeriesListThickness()
            if let splitView = horos_splitView {
                SeriesListLayout.setListVisible(visible, in: splitView, placement: placement, thickness: thickness)
            }
            horos_splitView?.resizeSubviews(withOldSize: horos_splitView?.bounds.size ?? .zero)

            if visible && horos_needsToBuildSeriesMatrix {
                buildMatrixPreview(false)
            }
        }

        UserDefaults.standard.set(visible, forKey: "SeriesListVisible")
    }

    @objc(observeValueForKeyPath:ofObject:change:context:)
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // [[change objectForKey: NSKeyValueChangeNewKey] intValue] as a BOOL:
        // a bool on arm64, a signed char (the low byte) on x86_64.
        let changed = ViewerSender.intValue(change?[.newKey])
        #if arch(x86_64)
        let newValue = Int8(truncatingIfNeeded: changed) != 0
        #else
        let newValue = changed != 0
        #endif
        // UserDefaults reports a default on the thread that wrote it: the main
        // thread for these.
        let viewer = self
        onMainActor {
            if viewerSameString(keyPath, SeriesListIdentification.defaultsKey) {
                viewer.setWindowTitle(viewer)
                viewer.buildMatrixPreview(false)
                viewer.horos_needsToBuildSeriesPopupMenu = true
                for case let view as DCMView in (viewer.imageViews() as NSArray?) ?? NSArray() {
                    view.needsDisplay = true
                }
                return
            }
            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
                return
            }

            if viewerSameString(keyPath, "SeriesListVisible") {
                if seriesListVisibleNoReentry == false {
                    seriesListVisibleNoReentry = true
                    for case let v as ViewerController in (ViewerController.getDisplayed2DViewers() as NSArray?) ?? NSArray() {
                        v.setMatrixVisible(newValue)
                    }
                    seriesListVisibleNoReentry = false
                }
            }
        }
    }

    @objc(autoHideMatrix)
    func autoHideMatrix() {
        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
            return
        }

        if UserDefaults.standard.bool(forKey: "AUTOHIDEMATRIX") == false {
            return
        }

        var hide = false
        var window: NSWindow? = nil

        if horos_windowWillClose {
            return
        }

        if fullScreenON() == false {
            window = self.window
            if window?.isKeyWindow != true {
                hide = true
            }
        } else {
            window = horos_FullScreenWindow
        }

        let mouse = window?.mouseLocationOutsideOfEventStream ?? .zero

        let isCurrentlyVisible = matrixIsVisible()

        if hide == false {
            if !SeriesListDock.mouseKeepsListShown(x: mouse.x, y: mouse.y, cellWidth: horos_previewMatrix?.cellSize.width ?? 0,
                                                   height: horos_splitView?.frame.size.height ?? 0, listShown: isCurrentlyVisible) {
                hide = true
            }
        }

        if isCurrentlyVisible == hide {
            let scaleValues = NSMutableArray()
            let originValues = NSMutableArray()

            for case let v as DCMView in (horos_seriesView?.imageViews() as NSArray?) ?? NSArray() {
                scaleValues.add(NSNumber(value: v.scaleValue))
                originValues.add(NSStringFromPoint(v.origin))
            }

            setMatrixVisible(!hide)

            var i = 0
            for case let v as DCMView in (horos_seriesView?.imageViews() as NSArray?) ?? NSArray() {
                v.displayIfNeeded()
                v.scaleValue = (scaleValues.object(at: i) as! NSNumber).floatValue
                v.origin = NSPointFromString(originValues.object(at: i) as! String)
                i += 1
            }

            propagateSettings()

            for case let v as DCMView in (horos_seriesView?.imageViews() as NSArray?) ?? NSArray() {
                v.displayIfNeeded()
            }
        }
    }

    @objc(previewMatrixScrollView)
    func previewMatrixScrollView() -> NSScrollView! {
        return horos_previewMatrixScrollView
    }

    @objc(previewRootView)
    func previewRootView() -> NSView! {
        return horos_previewRootView
    }

    @objc(splitView:effectiveRect:forDrawnRect:ofDividerAtIndex:)
    func splitView(_ s: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        if s === horos_splitView {
            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
                return .zero
            }
        }

        return proposedEffectiveRect
    }

    @objc(splitViewDidResizeSubviews:)
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if horos_windowWillClose {
            return
        }

        if (notification.object as AnyObject?) === horos_splitView {
            horos_previewMatrix?.sizeToCells()

            if UserDefaults.standard.bool(forKey: "AUTOHIDEMATRIX") == false && horos_FullScreenOn == false {
                // Show or hide the list in all viewers.
                if NSApplication.shared.currentEvent?.modifierFlags.contains(.option) != true {
                    if seriesListResizeInProgress == false {
                        seriesListResizeInProgress = true

                        let showMatrix = matrixIsVisible()

                        for case let v as ViewerController in (ViewerController.get2DViewers() as NSArray?) ?? NSArray() {
                            if v !== self {
                                if showMatrix != v.matrixIsVisible() {
                                    v.setMatrixVisible(showMatrix)
                                }
                            } else {
                                if v.matrixIsVisible() && horos_needsToBuildSeriesMatrix {
                                    buildMatrixPreview(false)
                                }
                            }
                        }
                        seriesListResizeInProgress = false
                    }
                }
            }
        }
    }

    @objc(splitViewWillResizeSubviews:)
    func splitViewWillResizeSubviews(_ notification: Notification) {
        if horos_windowWillClose {
            return
        }

        if (notification.object as AnyObject?) === horos_splitView {
            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") == false {
                // The whole window redraws while the split view resizes its panes.
                self.window?.contentView?.needsDisplay = true
            }
        }
    }

    @objc(splitView:canCollapseSubview:)
    func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        if sender === horos_splitView {
            // The image pane, whichever edge the list is docked on.
            if subview === SeriesListLayout.imagePane(of: sender, placement: seriesListPlacement) {
                return false
            }
        }

        return true
    }

    @objc(splitView:constrainSplitPosition:ofSubviewAt:)
    func splitView(_ sender: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        if horos_windowWillClose {
            return proposedPosition
        }

        if sender === horos_splitView {
            // The divider's position is the list's thickness only with the list
            // before the image pane, on the left or the top; on the right or
            // the bottom the list lies past the divider, so the position is
            // turned into a thickness and back.
            let placement = seriesListPlacement
            var thickness = SeriesListLayout.listThickness(forDividerPosition: proposedPosition, in: sender, placement: placement)

            if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
                return SeriesListLayout.dividerPosition(forListThickness: 0, in: sender, placement: placement)
            }

            let rcs = horosSeriesListThickness()

            // A strip across the top or bottom snaps to its own thickness; the
            // scroller only matters down a side.
            let across = placement == .top || placement == .bottom
            var scrollbarWidth: CGFloat = 0
            if !across, let scrollView = horos_previewMatrixScrollView {
                let scroller = scrollView.verticalScroller
                if BrowserController._scrollerStyle(scroller) != 1 {
                    if scrollView.hasVerticalScroller && scroller?.isHidden != true {
                        scrollbarWidth = scroller?.frame.size.width ?? 0
                    }
                }
            }

            thickness = SeriesListDock.snappedThickness(thickness, stripThickness: rcs, scrollerWidth: scrollbarWidth, across: across)

            return SeriesListLayout.dividerPosition(forListThickness: thickness, in: sender, placement: placement)
        }

        return proposedPosition
    }

    @objc(matrixIsVisible)
    func matrixIsVisible() -> Bool {
        if UserDefaults.standard.bool(forKey: "UseFloatingThumbnailsList") {
            return true
        }

        let placement = seriesListPlacement
        let thickness = horosSeriesListThickness()
        let r = horos_splitView.map { SeriesListLayout.isListVisible(in: $0, placement: placement, thickness: thickness) } ?? false

        if UserDefaults.standard.bool(forKey: "SeriesListVisible") != r {
            UserDefaults.standard.set(r, forKey: "SeriesListVisible")
        }

        return r
    }

    @objc(splitView:resizeSubviewsWithOldSize:)
    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        if horos_windowWillClose {
            return
        }

        if sender === horos_splitView {
            let placement = seriesListPlacement
            var thickness = matrixIsVisible() ? horosSeriesListThickness() : 0
            // The constraint works on the divider's position, which is measured
            // from the far end when the list is on the right or the bottom.
            let dividerPosition = splitView(sender, constrainSplitPosition: SeriesListLayout.dividerPosition(forListThickness: thickness, in: sender, placement: placement),
                                            ofSubviewAt: 0)
            thickness = SeriesListLayout.listThickness(forDividerPosition: dividerPosition, in: sender, placement: placement)

            let splitFrame = sender.frame

            if splitFrame.size.height.isNaN || splitFrame.size.height < 0 || splitFrame.size.width.isNaN || splitFrame.size.width < 0 {
                NSLog("******* splitView:(NSSplitView*)sender resizeSubviewsWithOldSize:(NSSize)oldSize - %f", splitFrame.size.height)
                return
            }

            // Any edge, not only a left dock.
            SeriesListLayout.resizeSubviews(of: sender, placement: placement, thickness: thickness)
        }
    }

    @objc(observeScrollerStyleDidChangeNotification:)
    func observeScrollerStyleDidChangeNotification(_ n: Notification!) {
        horos_splitView?.resizeSubviews(withOldSize: horos_splitView?.bounds.size ?? .zero)
    }

    @objc(mouseMoved:)
    override func mouseMoved(with theEvent: NSEvent) {
        mouseMoved()
    }

    @objc(mouseMoved)
    func mouseMoved() {
        if window?.isVisible != true && !fullScreenON() {
            return
        }

        if horos_windowWillClose { return }

        autoHideMatrix()
    }
}
