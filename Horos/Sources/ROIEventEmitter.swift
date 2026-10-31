//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The events of a ROI's editing in a view, by what happened. Each is posted
/// as the notification the viewer, the ROI windows, the ROI manager and
/// plugins observe, with the same name, object and user info: the names are
/// a contract and stay.
@MainActor
enum ROIEventEmitter {

    /// A ROI was selected: OsirixROISelectedNotification, with the ROI.
    static func selected(_ roi: ROI) {
        post(.OsirixROISelected, object: roi)
    }

    /// A ROI is about to leave its list: OsirixRemoveROINotification, with
    /// the ROI. Its observers may release it: the caller holds it until it
    /// is removed.
    static func willRemove(_ roi: ROI) {
        post(.OsirixRemoveROI, object: roi)
    }

    /// ROIs left a list: OsirixROIRemovedFromArrayNotification, without an object.
    static func removedFromList() {
        post(.OsirixROIRemovedFromArray, object: nil)
    }

    /// A ROI was added to the image `slice` of a view:
    /// OsirixAddROINotification, with the view, the ROI and the slice number.
    static func added(_ roi: ROI, to view: DCMView, slice: Int32) {
        post(.OsirixAddROI, object: view, userInfo: ["ROI": roi, "sliceNumber": NSNumber(value: slice)])
    }

    /// A ROI changed: OsirixROIChangeNotification, with the ROI.
    static func changed(_ roi: ROI) {
        post(.OsirixROIChange, object: roi)
    }

    private static func post(_ name: Notification.Name, object: AnyObject?, userInfo: [AnyHashable: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: object, userInfo: userInfo)
    }
}
