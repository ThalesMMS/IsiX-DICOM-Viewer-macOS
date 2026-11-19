//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Cocoa
import IsiXImaging
import IsiXPreferences

/// A plane of the 3D MPR or of the curved MPR, as Sync Zoom sees it: its
/// camera, whose parallel scale is its zoom, and its reconstruction.
@MainActor
protocol ZoomSyncedPlane: AnyObject {
    var camera: Camera! { get }
    func restoreCamera()
    func updateViewMPR(_ computeCrossReferenceLines: Bool)
}

extension MPRDCMView: ZoomSyncedPlane {}
extension CPRMPRDCMView: ZoomSyncedPlane {}

/// A window whose three planes Sync Zoom keeps at one zoom.
@MainActor
protocol ZoomSyncedWindow: AnyObject {
    /// The three planes, in their order.
    var zoomSyncedPlanes: [(any ZoomSyncedPlane)?] { get }
    /// The plane the others follow when the setting is turned on.
    var selectedZoomSyncedPlane: (any ZoomSyncedPlane)? { get }
    /// Whether Sync Zoom is on, as the cross-reference lines of the window read it.
    var syncsZoom: Bool { get }
    /// Whether the window is closing: its planes are not reconstructed then.
    var isClosingZoomSyncedWindow: Bool { get }
    /// Whether the planes are reconstructed at the coarser sample distance of
    /// an interaction under way. The window leaves it on after the full pass
    /// that follows a wheel step.
    var lowLOD: Bool { get set }
}

extension MPRController: ZoomSyncedWindow {
    var zoomSyncedPlanes: [(any ZoomSyncedPlane)?] { [mprView1, mprView2, mprView3] }
    var selectedZoomSyncedPlane: (any ZoomSyncedPlane)? { selectedView() }
    var syncsZoom: Bool { Self.planesLayoutZoomSync.value(in: preferenceStore) }
    var isClosingZoomSyncedWindow: Bool { windowWillClose() }
}

extension CPRController: ZoomSyncedWindow {
    var zoomSyncedPlanes: [(any ZoomSyncedPlane)?] { [mprView1, mprView2, mprView3] }
    var selectedZoomSyncedPlane: (any ZoomSyncedPlane)? { selectedView() }
    var syncsZoom: Bool { MPRController.planesLayoutZoomSync.value(in: preferenceStore) }
    var isClosingZoomSyncedWindow: Bool { windowWillClose() }
}

/// Sync Zoom of one 3D MPR or curved MPR window.
///
/// The Sync Zoom button only writes its setting, through a binding, and the
/// cross-reference lines of the window carry the zoom of the selected plane to
/// the other two only when that plane asks for them with itself as the sender:
/// at the end of a drag of the zoom tool. Neither the button nor a pinch, which
/// reconstructs the plane under the pointer alone while it lasts, reaches the
/// other planes that way. This observes the setting for as long as the window
/// keeps it, is told of the end of a pinch by the plane, and brings the other
/// planes to the zoom at the moments MPRZoomSync names.
@MainActor
final class MPRZoomSynchronizer: NSObject {
    private weak var window: (any ZoomSyncedWindow)?

    /// The key path of the setting in the shared defaults controller, which
    /// the binding of the button writes.
    private static let settingKeyPath = ReconstructionPreferences.controllerKeyPath(MPRController.planesLayoutZoomSync.key)

    init(window: any ZoomSyncedWindow) {
        self.window = window
        super.init()
        NSUserDefaultsController.shared.addObserver(self, forKeyPath: Self.settingKeyPath, options: .new, context: nil)
    }

    isolated deinit {
        NSUserDefaultsController.shared.removeObserver(self, forKeyPath: Self.settingKeyPath)
    }

    nonisolated override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        // The defaults controller reports a default on the thread that wrote it.
        onMainActor { [weak self] in
            guard let self, let window = self.window else { return }
            self.zoomChanged(at: .settingChanged, in: window.selectedZoomSyncedPlane)
        }
    }

    /// A pinch over `plane` ended or was cancelled, and the plane has been
    /// reconstructed at its final zoom.
    func pinchEnded(in plane: any ZoomSyncedPlane) {
        zoomChanged(at: .pinchEnded, in: plane)
    }

    /// The zoom of `plane` changed, or the setting did, at `moment`: the other
    /// planes take the zoom of `plane` when MPRZoomSync says so, each
    /// reconstructed once, without asking the others to follow in turn.
    func zoomChanged(at moment: MPRZoomSync.Moment, in plane: (any ZoomSyncedPlane)?) {
        guard let window, !window.isClosingZoomSyncedWindow,
              MPRZoomSync.propagates(at: moment, isOn: window.syncsZoom),
              let plane, let scale = plane.camera?.parallelScale else { return }

        let planes = window.zoomSyncedPlanes
        guard let source = planes.firstIndex(where: { $0 === plane }) else { return }
        let followers = MPRZoomSync.followers(of: source, scales: planes.map { $0?.camera?.parallelScale })
        if followers.isEmpty { return }

        // Turning the setting on is not an interaction, and nothing redraws
        // the planes that follow after it: they are drawn at full detail, as
        // the window's own full pass draws them, and the flag goes back to
        // what the window had.
        let wasLow = window.lowLOD
        window.lowLOD = false
        defer { window.lowLOD = wasLow }

        for index in followers {
            guard let follower = planes[index], let camera = follower.camera else { continue }
            camera.parallelScale = scale
            camera.forceUpdate = true
            follower.restoreCamera()
            follower.updateViewMPR(false)
        }
        // The planes share the hidden 3D view: it is left on the camera of
        // the plane the zoom came from, as it was.
        plane.restoreCamera()
    }

    /// The cameras of the other planes given the zoom of `selected`, for the
    /// cross-reference lines, which reconstruct those planes themselves.
    static func carryZoom(of selected: (any ZoomSyncedPlane)?, to planes: [(any ZoomSyncedPlane)?]) {
        guard let scale = selected?.camera?.parallelScale else { return }
        for case let plane? in planes where plane !== selected {
            plane.camera?.parallelScale = scale
        }
    }
}
