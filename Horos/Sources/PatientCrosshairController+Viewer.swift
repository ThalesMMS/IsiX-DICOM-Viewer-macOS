//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// The patient crosshair as a 2D viewer publishes and reads it: through the
/// viewer's volume session, or, for a second window on a series another
/// viewer holds, which has no session of its own, through its volume
/// identity. Geometry and volume ownership stay with the viewer. Main thread.
extension PatientCrosshairController {

    /// Publishes `point` (patient millimetres, 3 values) for `viewer`, on
    /// behalf of `owner` (the viewer, or the MPR window that placed it). NO
    /// when the viewer is closing or has neither a session nor an identity.
    @discardableResult
    func publish(_ point: UnsafePointer<Float>, viewer: ViewerController?, owner: AnyObject?) -> Bool {
        guard let viewer, !viewer.windowWillClose(), let owner else { return false }
        let x = Double(point[0]), y = Double(point[1]), z = Double(point[2])
        if let session = viewer.horosVolumeSession() {
            return publish(x: x, y: y, z: z, session: session, owner: owner)
        }
        guard let identity = viewer.horosVolumeIdentity() else { return false }
        return publish(x: x, y: y, z: z, identity: identity, owner: owner)
    }

    /// The current point as `viewer` shows it, or nil when it is in another
    /// patient world. A point placed by a viewer registered with this one, or
    /// by an orthogonal MPR of such a viewer, is shown whatever its frame.
    func point(forViewer viewer: ViewerController?) -> PatientCrosshairPoint? {
        guard let viewer, !viewer.windowWillClose(), currentPoint != nil else { return nil }
        let source: ViewerController?
        switch sourceOwner {
        case let owner as ViewerController: source = owner
        case let owner as OrthogonalMPRViewer: source = owner.viewerController()
        default: source = nil
        }
        let registered = source.map { viewer.registeredViewer() === $0 || $0.registeredViewer() === viewer } ?? false
        let useFrame = UserDefaults.standard.bool(forKey: ViewerReferenceLines.frameOfReferencePreferenceKey)
        if let session = viewer.horosVolumeSession() {
            return point(for: session, registered: registered, useFrameOfReference: useFrame)
        }
        guard let identity = viewer.horosVolumeIdentity() else { return nil }
        return point(for: identity, registered: registered, useFrameOfReference: useFrame)
    }
}
