//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// When a still press becomes an image export, and when WW/WL must keep the pointer.
///
/// A one-second still press starts the file-promise drag. Any movement before
/// that is clinical (window, scroll, ROI) and cancels the wait. Once the export
/// session is running, clinical tools stay out of the way until the drop ends.
/// Finder and browsers need Copy; Generic alone is why those drops died.
@objc(HorosViewerImageDrag)
public final class ViewerImageDrag: NSObject {
    @objc(HorosViewerImageDragPhase)
    public enum Phase: Int {
        case idle
        case waitingToExport
        case exporting
    }

    /// mouseUp and the press timer must not clear a session that already started.
    @objc public static let clearsExportSessionWhenCancellingWait = false

    @objc(shouldCancelWaitForClinicalMoveWithDeltaX:deltaY:)
    public static func shouldCancelWait(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        deltaX != 0 || deltaY != 0
    }

    @objc(shouldIgnoreClinicalDragInPhase:)
    public static func shouldIgnoreClinicalDrag(in phase: Phase) -> Bool {
        phase == .exporting
    }

    @objc(sourceOperationMaskOutsideApplication:)
    public static func sourceOperationMask(outsideApplication: Bool) -> UInt {
        outsideApplication ? NSDragOperation.copy.rawValue : NSDragOperation.generic.rawValue
    }
}
