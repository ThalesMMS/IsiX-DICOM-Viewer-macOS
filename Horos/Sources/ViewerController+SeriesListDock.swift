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

// The docked series list of the 2D viewer: the selectors of its dock and the
// split view's delegate, which the viewer's SeriesListPresenter answers.

// The class does not declare NSSplitViewDelegate in Swift: this file does, so
// that the methods below implement the protocol's (ViewerController.h).
extension ViewerController: NSSplitViewDelegate {}

public extension ViewerController {

    @objc(checkFrameSize)
    func checkFrameSize() -> Bool {
        matrixIsVisible()
    }

    /// How thick the series list strip has to be on the stored edge.
    @objc(horosSeriesListThickness)
    func horosSeriesListThickness() -> CGFloat {
        seriesListPresenter.thickness()
    }

    @objc(updateSeriesListMode)
    func updateSeriesListMode() {
        seriesListPresenter.updateMode()
    }

    @objc(setMatrixVisible:)
    func setMatrixVisible(_ visible: Bool) {
        seriesListPresenter.setListVisible(visible)
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
            viewer.seriesListPresenter.preferenceChanged(keyPath, newValue: newValue)
        }
    }

    @objc(autoHideMatrix)
    func autoHideMatrix() {
        seriesListPresenter.autoHide()
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
        seriesListPresenter.effectiveRect(of: s, proposed: proposedEffectiveRect)
    }

    @objc(splitViewDidResizeSubviews:)
    func splitViewDidResizeSubviews(_ notification: Notification) {
        seriesListPresenter.splitViewDidResize(notification)
    }

    @objc(splitViewWillResizeSubviews:)
    func splitViewWillResizeSubviews(_ notification: Notification) {
        seriesListPresenter.splitViewWillResize(notification)
    }

    @objc(splitView:canCollapseSubview:)
    func splitView(_ sender: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        seriesListPresenter.canCollapse(subview, of: sender)
    }

    @objc(splitView:constrainSplitPosition:ofSubviewAt:)
    func splitView(_ sender: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt offset: Int) -> CGFloat {
        seriesListPresenter.constrainedDividerPosition(proposedPosition, of: sender)
    }

    @objc(matrixIsVisible)
    func matrixIsVisible() -> Bool {
        seriesListPresenter.isListVisible()
    }

    @objc(splitView:resizeSubviewsWithOldSize:)
    func splitView(_ sender: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        seriesListPresenter.resizeSubviews(of: sender)
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
        seriesListPresenter.mouseMoved()
    }
}
