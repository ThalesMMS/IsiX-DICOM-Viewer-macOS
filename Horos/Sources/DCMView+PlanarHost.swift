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
import ObjectiveC
import QuartzCore

/// What a view keeps for its Metal picture between draws: its renderer, why
/// its last picture was not drawn, the MPR's notice, its trace, and the
/// copies it reuses while what they were made from does not change (the
/// image's samples, a thick slab's other slices).
@MainActor final class PlanarHostState {
    var renderer: PlanarHostRenderer?
    /// Why the view's own draw gave no picture, or nil.
    var fallback: String?
    /// The MPR engine's notice: its plane came from the original renderer.
    var engineNotice: String?
    var trace: PlanarPerformanceTrace?
    /// The thick slab's other slices, recognised by the address of each
    /// image and of its pixels.
    var slabKey: String?
    var slabData: Data?
    /// One immutable copy of the image's samples, bounded by the plane shown.
    var scalarSnapshot: NSData?
}

/// The view's picture is drawn with Metal. Rendering changes only; the
/// controllers, DICOM pixels and plugin APIs stay the host's. What is drawn is
/// the planar snapshot (DCMView+PlanarSnapshot.swift); PlanarHostRenderer
/// draws it. Main thread only.
extension DCMView {

    nonisolated(unsafe) private static var planarHostKey: UInt8 = 0

    /// The first reason a capture got no picture, until reset.
    private static var captureFailure: String?

    var planarHostState: PlanarHostState {
        if let state = objc_getAssociatedObject(self, &Self.planarHostKey) as? PlanarHostState { return state }
        let state = PlanarHostState()
        objc_setAssociatedObject(self, &Self.planarHostKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The volume session of the view's viewer, when it has one: the 2D
    /// viewer's. The MPR, orthogonal, endoscopy and preview views draw without one.
    var planarSession: VolumeSession? {
        return (windowController() as? ViewerController)?.horosVolumeSession()
    }

    // MARK: - Diagnostics

    @objc(horosPlanarPerformanceTrace)
    func horosPlanarPerformanceTrace() -> PlanarPerformanceTrace? {
        guard PlanarPerformanceTrace.enabled else { return nil }
        let state = planarHostState
        if let trace = state.trace { return trace }
        let trace = PlanarPerformanceTrace()
        state.trace = trace
        return trace
    }

    /// The GPU time of the last command the view's renderer encoded, or -1.
    @objc(horosPlanarLastCommandMilliseconds)
    func horosPlanarLastCommandMilliseconds() -> Double {
        guard let renderer = planarHostState.renderer, renderer.encodedGPUCommand, renderer.gpuMilliseconds > 0 else { return -1 }
        return renderer.gpuMilliseconds
    }

    /// Which submission path drew the last planar frame, or an empty string
    /// when none has. The picture is the same either way.
    @objc(horosPlanarBackendName)
    func horosPlanarBackendName() -> String { planarHostState.renderer?.backendName ?? "" }

    /// The GPU time the last planar submission reported, in milliseconds.
    @objc(horosPlanarGPUMilliseconds)
    func horosPlanarGPUMilliseconds() -> Double { planarHostState.renderer?.gpuMilliseconds ?? 0 }

    // MARK: - Notices

    /// Why the picture was not drawn, or the MPR's notice, or nil.
    @objc(horosPlanarFallbackReason)
    func horosPlanarFallbackReason() -> String? {
        let state = planarHostState
        return state.fallback ?? state.engineNotice
    }

    /// The MPR's notice, when it has set one.
    @objc(horosEngineNotice)
    func horosEngineNotice() -> String? { planarHostState.engineNotice }

    /// Lets the MPR show the same paused-renderer notice: its plane came from
    /// the original renderer. It stays until the MPR clears it, whatever the
    /// picture's own draw does.
    @objc(horosSetPlanarFallbackReason:)
    func horosSetPlanarFallbackReason(_ reason: String?) {
        planarHostState.engineNotice = reason
    }

    // MARK: - Caches

    /// Drops the renderer, its textures and the copies kept between draws.
    @objc(horosInvalidatePlanar)
    func horosInvalidatePlanar() {
        let state = planarHostState
        state.scalarSnapshot = nil
        state.renderer?.invalidate()
        state.renderer = nil
        state.fallback = nil
    }

    /// Drops the thick slab slices kept between draws. They are recognised by
    /// the address of each image and of its pixels: a caller that rewrites
    /// the pixels of the same images in place calls this, or the next draw
    /// reduces the old ones.
    @objc(horosPlanarForgetSlab)
    func horosPlanarForgetSlab() {
        let state = planarHostState
        state.scalarSnapshot = nil
        state.slabKey = nil
        state.slabData = nil
    }

    // MARK: - Drawing

    @objc(horosPlanarRenderer)
    func horosPlanarRenderer() -> PlanarHostRenderer {
        let state = planarHostState
        if let renderer = state.renderer { return renderer }
        let renderer = PlanarHostRenderer()
        state.renderer = renderer
        return renderer
    }

    /// A snapshot that can be drawn, or nil with the reason recorded.
    private func drawablePlanarSnapshot() -> NSDictionary? {
        let snapshot = horosPlanarSnapshot()
        guard snapshot["error"] == nil else {
            horosInvalidatePlanar()
            planarHostState.fallback = NSLocalizedString("This image cannot be displayed.", comment: "")
            return nil
        }
        return snapshot
    }

    /// Draws the view's picture into its layer and presents it with the
    /// current transaction; NO, with a reason, when it cannot.
    @objc(horosDrawPlanarInLayer:inverted:)
    func horosDrawPlanar(in layer: CAMetalLayer, inverted: Bool) -> Bool {
        assert(Thread.isMainThread, "Planar rendering requires the main thread")
        guard let snapshot = drawablePlanarSnapshot() else { return false }
        let drawn = horosPlanarRenderer().draw(snapshot: snapshot, session: planarSession, layer: layer, inverted: inverted)
        planarHostState.fallback = drawn ? nil : NSLocalizedString("This image cannot be displayed.", comment: "")
        return drawn
    }

    /// A frame with no picture: the clear colour, white or black, inverted with the view.
    @objc(horosClearLayer:white:inverted:)
    func horosClear(_ layer: CAMetalLayer, white: Bool, inverted: Bool) {
        horosPlanarRenderer().clear(layer: layer, white: white, inverted: inverted)
    }

    // MARK: - Captures

    /// The picture the view shows, BGRA, rows from the top, `width` x
    /// `height` backing pixels, as it draws it: for a capture.
    @objc(horosPlanarPixelsWidth:height:inverted:)
    func horosPlanarPixelsWidth(_ width: Int, height: Int, inverted: Bool) -> Data? {
        assert(Thread.isMainThread, "Planar rendering requires the main thread")
        let snapshot = drawablePlanarSnapshot()
        let pixels = snapshot.flatMap {
            horosPlanarRenderer().render(snapshot: $0, session: planarSession, width: width, height: height, inverted: inverted)
        }
        // A view with no image has no picture to give; one with an image failed.
        if pixels == nil && curDCM != nil {
            let reason = (snapshot != nil ? horosPlanarRenderer().failureReason : nil)
                ?? NSLocalizedString("This image cannot be displayed.", comment: "")
            NSLog("Horos planar: no picture for a capture of %ld x %ld: %@", width, height, reason)
            if Self.captureFailure == nil { Self.captureFailure = reason }
        }
        return pixels
    }

    /// Why a view with an image gave no picture to a capture since
    /// horosResetCaptureFailure(), or nil. Such a capture leaves the
    /// background where the picture goes: what writes it to a file asks first.
    @objc(horosCaptureFailure)
    class func horosCaptureFailure() -> String? {
        assert(Thread.isMainThread, "Captures are made on the main thread")
        return captureFailure
    }

    @objc(horosResetCaptureFailure)
    class func horosResetCaptureFailure() {
        assert(Thread.isMainThread, "Captures are made on the main thread")
        captureFailure = nil
    }

    /// The same picture magnified: the square of `side` backing pixels whose
    /// top left, top right and bottom left corners show these points of the
    /// view's bounds.
    @objc(horosPlanarPixelsSide:topLeft:topRight:bottomLeft:inverted:)
    func horosPlanarPixelsSide(_ side: Int, topLeft: NSPoint, topRight: NSPoint, bottomLeft: NSPoint, inverted: Bool) -> Data? {
        assert(Thread.isMainThread, "Planar rendering requires the main thread")
        let snapshot = horosPlanarSnapshot()
        guard snapshot["error"] == nil, side > 0 else { return nil }
        // The view's own mapping, onto a square: the image pixels its three
        // corners show, as the snapshot works them out for the bounds.
        func lens(_ layer: NSDictionary, of view: DCMView) -> NSMutableDictionary {
            let a = view.horosPixel(at: topLeft, drawnIn: self), b = view.horosPixel(at: topRight, drawnIn: self),
                c = view.horosPixel(at: bottomLeft, drawnIn: self)
            let result = NSMutableDictionary(dictionary: layer)
            result["screenToPixel"] = [a.x, a.y, b.x, b.y, c.x, c.y]
            result["viewSize"] = [side, side]
            return result
        }
        let magnified = lens(snapshot, of: self)
        magnified.removeObject(forKey: "fusion")
        if let fusion = snapshot["fusion"] as? NSDictionary, let fused = blending {
            magnified["fusion"] = lens(fusion, of: fused)
        }
        // A renderer of its own: the view's keeps the frame it shows.
        return PlanarHostRenderer().render(snapshot: magnified, session: nil, width: side, height: side, inverted: inverted)
    }
}

extension ViewerController {
    /// Always YES: every view draws its picture with Metal.
    @objc(horosPlanarMetalEnabled)
    func horosPlanarMetalEnabled() -> Bool { true }
}
