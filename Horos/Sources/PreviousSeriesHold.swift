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
import ObjectiveC

/// The series a 2D viewer showed before a change of plane, held for the 3D
/// windows opened on it.
///
/// An MPR, a volume rendering and the other 3D windows do not own the slices,
/// the files or the volume they show: the viewer that opened them does, and
/// they close when it lets them go. A change of plane gives the viewer new
/// slices while those windows stay open on the former ones. Each of them then
/// takes a hold on what the viewer releases, for as long as its controller
/// lives, and is named in the announcement of the release so that it does not
/// close on it. A window that holds a series of the viewer stays open through
/// its later changes of plane too: nothing it shows is released by them.
@objc(HorosPreviousSeriesHold)
public final class PreviousSeriesHold: NSObject {
    /// In the userInfo of the viewer's closing announcement, when a change of
    /// plane is what releases the series: the window controllers that go on
    /// showing it, an array that may be empty.
    @objc public static let keptWindowsKey = "HorosWindowsKeepingPreviousSeries"

    private static let holdsKey = IdentityToken()

    private let objects: [AnyObject]
    /// The viewer that released them, which is not retained: it is only
    /// compared with the viewer of an announcement.
    private let viewer: ObjectIdentifier

    private init(_ objects: [AnyObject], viewer: AnyObject) {
        self.objects = objects
        self.viewer = ObjectIdentifier(viewer)
    }

    private static func holds(of owner: AnyObject) -> [PreviousSeriesHold] {
        (objc_getAssociatedObject(owner, holdsKey.key) as? [PreviousSeriesHold]) ?? []
    }

    /// `owner` keeps `objects`, which `viewer` releases, until it is
    /// deallocated. A second hold is added to the first.
    @objc(holdObjects:releasedByViewer:forOwner:)
    public static func hold(_ objects: [AnyObject], releasedBy viewer: AnyObject, for owner: AnyObject) {
        objc_setAssociatedObject(owner, holdsKey.key, holds(of: owner) + [PreviousSeriesHold(objects, viewer: viewer)],
                                 .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Whether `owner` shows a series `viewer` no longer has.
    @objc(owner:holdsPreviousSeriesOfViewer:)
    public static func owner(_ owner: AnyObject, holdsPreviousSeriesOf viewer: AnyObject) -> Bool {
        holds(of: owner).contains { $0.viewer == ObjectIdentifier(viewer) }
    }

    /// Whether `window` stays open through `note`, the announcement of a
    /// viewer releasing its series: a change of plane that names it among the
    /// windows keeping that series, or one of a viewer whose former series it
    /// already holds. Any other release closes it: the viewer closing, another
    /// series taking its place, or the change of plane of a viewer it only
    /// borrows from (a fused series).
    @objc(window:keepsSeriesReleasedBy:)
    public static func window(_ window: AnyObject, keepsSeriesReleasedBy note: Notification?) -> Bool {
        guard let kept = note?.userInfo?[keptWindowsKey] as? [AnyObject] else { return false }
        if kept.contains(where: { $0 === window }) { return true }
        guard let viewer = note?.object as AnyObject? else { return false }
        return owner(window, holdsPreviousSeriesOf: viewer)
    }
}
