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
import IsiXImaging
import ObjectiveC

/// A fused plane resliced with the image's, owned until the view's blending
/// branch takes it: the malloc-owned buffer VTK's own path would hand over.
final class MPRFusedPlane {
    var pixels: UnsafeMutablePointer<Float>?
    let width: Int, height: Int
    let milliseconds: Double

    init(pixels: UnsafeMutablePointer<Float>, width: Int, height: Int, milliseconds: Double) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.milliseconds = milliseconds
    }

    deinit { free(pixels) }
}

/// What one MPR view keeps of its last Metal plane until the view takes it:
/// the fused plane, the cubic display plane, and whether the image handed
/// over is an RGB volume's ARGB bytes.
@MainActor final class MPRMetalPlaneState {
    var fusedPlane: MPRFusedPlane?
    var displayPlane: NSData?
    var colourImage = false
}

/// An MPR view's plane, resliced in Metal from the window's volume
/// (MPRController+MetalHost.swift) with VTK's camera, slab and mode; the view
/// draws it as it drew VTK's. Main thread only.
extension MPRDCMView {

    nonisolated(unsafe) private static var metalPlaneKey: UInt8 = 0

    private var metalPlane: MPRMetalPlaneState {
        if let state = objc_getAssociatedObject(self, &Self.metalPlaneKey) as? MPRMetalPlaneState { return state }
        let state = MPRMetalPlaneState()
        objc_setAssociatedObject(self, &Self.metalPlaneKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// A malloc-owned buffer of `count` floats, which the view frees, or nil.
    private static func floats(_ count: Int) -> UnsafeMutablePointer<Float>? {
        return malloc(count * MemoryLayout<Float>.size)?.bindMemory(to: Float.self, capacity: count)
    }

    /// The nine cosines as the reslice takes them.
    private static func numbers(_ values: [Float]) -> [NSNumber] { values.map { NSNumber(value: $0) } }

    /// The plane's pixel (0, 0) centre, its nine cosines and its pixel
    /// spacing, as the reslice takes them; the slab's sample step is the
    /// volume's.
    private func metalPlaneGeometry(_ vrView: NSView & HorosMPRVRViewMessages) -> (origin: [NSNumber], orientation: [NSNumber], spacing: Double) {
        var cosines = [Float](repeating: 0, count: 9), corner = [Float](repeating: 0, count: 3)
        vrView.getOrientation(&cosines)
        vrView.getOrigin(&corner, windowCentered: true, sliceMiddle: true)
        let spacing = vrView.getResolution() * Double(vrView.imageSampleDistance())
        let centre = MPRPlaneRules.pixelCentre(corner: corner, cosines: cosines, spacing: spacing)
        return (centre.map { NSNumber(value: $0) }, Self.numbers(cosines), spacing)
    }

    /// The outcome of a plane, for the window's reason and the view's notice.
    private func recordMetalPlane(reason: String?, controller: MPRController?) {
        controller?.metalHost.fallbackReason = reason
        horosSetPlanarFallbackReason(reason)
    }

    // MARK: - The plane

    /// Returns a malloc-owned float image after preparing the camera
    /// geometry. Nil asks for the normal CPU render. Main thread only.
    @objc(horosMPRCopyImageWidth:height:)
    func horosMPRCopyImageWidth(_ width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<Float>? {
        assert(Thread.isMainThread, "MPR reslice requires the main thread")
        let controller = horosMPRWindowController
        let plane = metalPlane
        controller?.metalHost.lastMilliseconds = nil
        plane.fusedPlane = nil
        plane.displayPlane = nil
        plane.colourImage = false
        vrView?.horosSetMPRVolumeMetal(false)
        MPRCubicDisplayObserver.start()
        guard !moveCenter, let vrView else { return nil }
        let mode = Int(controller?.clippingRangeMode ?? 0)
        // Volume rendering mode: VTK renders the plane, and the 3D window's
        // Metal ray cast (VolumeMetalRenderer) fills its ray-cast image, with
        // the camera, slab, window, CLUT, opacity, shading and a fused series
        // VTK holds; -horosMPRVolumeRendered reports the outcome.
        guard let controller, MPRPlaneRules.reslices(projectionMode: mode) else {
            vrView.horosSetMPRVolumeMetal(true)
            return nil
        }
        // The view's own pix may still be the colour picture volume rendering
        // left, one frame after the mode changes: the volume decides.
        var reason: String?
        let volume = controller.metalCurrentVolume(reason: &reason)
        if let volume, volume.isColour {
            return copyColourImage(width: width, height: height, volume: volume, controller: controller, vrView: vrView)
        }
        var reslicer = volume.flatMap { controller.metalReslicer(for: $0, reason: &reason) }
        // The host's share of a Metal plane, for the trace: the geometry and
        // arguments before the reslice, and the copy after it.
        let preparedFrom = MetalPerformanceTrace.hostTime()
        // One reason per cause, so that the trace counts which camera or crop refuses.
        if reslicer != nil, let geometry = vrView.horosMPRGeometryRefusalWidth(width, height: height) {
            reslicer = nil
            reason = geometry
        }
        // A fused series is resliced in Metal with the plane or both stay with
        // VTK, so a view never mixes the two engines. The plane waits for the
        // view's blending branch, which takes it instead of VTK's.
        let fused = reslicer != nil && blending != nil ? metalFusedPlane(controller: controller, vrView: vrView, reason: &reason) : nil
        if blending != nil && fused == nil { reslicer = nil }
        if let reslicer, let volume {
            let geometry = metalPlaneGeometry(vrView)
            let step = volume.sampleStep
            MetalPerformanceTrace.recordHost("mpr.host_prepare", startedAt: preparedFrom)
            // The view owns the image it is handed; the engine copies the plane into it, once.
            let w = width.pointee, h = height.pointee
            if let image = w > 0 && h > 0 ? Self.floats(w * h) : nil {
                do {
                    try reslicer.reslice(origin: geometry.origin, orientation: geometry.orientation, spacing: geometry.spacing,
                                         width: w, height: h, thickness: vrView.getClippingRangeThicknessInMm(),
                                         sampleStep: step, projection: mode, background: Double(volume.background), into: image)
                    var milliseconds = reslicer.lastMilliseconds + (fused?.milliseconds ?? 0)
                    // The cubic display plane: the same thin slab, no fused
                    // series. The linear one above stays the pixels; this one is only drawn.
                    let thickness = Float(vrView.getClippingRangeThicknessInMm())
                    if MPRPlaneRules.drawsCubicDisplayPlane(preference: controller.horosMPRCubicDisplay(), fused: fused != nil,
                                                            thickness: thickness),
                       let display = Self.floats(w * h) {
                        do {
                            try reslicer.reslice(origin: geometry.origin, orientation: geometry.orientation, spacing: geometry.spacing,
                                                 width: w, height: h, thickness: Double(thickness), sampleStep: step,
                                                 projection: mode, background: Double(volume.background), interpolation: 1,
                                                 into: display)
                            milliseconds += reslicer.lastMilliseconds
                            plane.displayPlane = NSData(bytesNoCopy: display, length: w * h * MemoryLayout<Float>.size,
                                                        freeWhenDone: true)
                        } catch {
                            free(display)
                        }
                    }
                    controller.metalHost.lastMilliseconds = milliseconds
                    plane.fusedPlane = fused
                    recordMetalPlane(reason: nil, controller: controller)
                    return image
                } catch {
                    free(image)
                    reason = error.localizedDescription
                }
            } else {
                reason = "The reconstructed plane could not be allocated."
            }
        }
        if let reason { MetalPerformanceTrace.recordRefusal("mpr.refusal", reason: reason) }
        recordMetalPlane(reason: reason, controller: controller)
        return nil
    }

    /// An RGB volume's plane: each channel resliced as a scalar volume on the
    /// plane's grid, all three in one GPU submission, and the three combined
    /// through the ray caster's own tables (MPRColourPlane). ARGB bytes, which
    /// the view takes as it takes VTK's colour plane. When this plane is
    /// refused, the CPU ray cast draws it, with the same per-channel maximum,
    /// minimum and mean.
    private func copyColourImage(width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>, volume: MPRHostVolume,
                                 controller: MPRController, vrView: NSView & HorosMPRVRViewMessages) -> UnsafeMutablePointer<Float>? {
        var reason: String? = blending != nil ? "A series fused over an RGB volume keeps the original renderer." : nil
        if reason == nil { reason = vrView.horosMPRGeometryRefusalWidth(width, height: height) }
        let tables = reason == nil ? vrView.horosMPRColourTables() : nil
        if let error = tables?["error"] { reason = error as? String }
        if reason == nil, let reslicers = controller.metalColourReslicers(for: volume, reason: &reason) {
            let geometry = metalPlaneGeometry(vrView)
            let w = width.pointee, h = height.pointee
            // The three channels in one GPU submission. A ray with no sample
            // inside the volume stays black, as VTK leaves it.
            let bytes = VolumeAllocation.byteCount(width: w, height: h, slices: 1, bytesPerVoxel: 4)
            if let image = bytes > 0 ? malloc(bytes) : nil {
                do {
                    try MPRReslicerBridge.resliceColour(reslicers, origin: geometry.origin, orientation: geometry.orientation,
                                                       spacing: geometry.spacing, width: w, height: h,
                                                       thickness: vrView.getClippingRangeThicknessInMm(), sampleStep: volume.sampleStep,
                                                       projection: Int(controller.clippingRangeMode),
                                                       background: Double(volume.background),
                                                       tables: tables?["tables"] as? [NSDictionary] ?? [],
                                                       into: image, capacity: bytes)
                    metalPlane.colourImage = true
                    controller.metalHost.lastMilliseconds = reslicers.first?.lastMilliseconds ?? 0
                    recordMetalPlane(reason: nil, controller: controller)
                    return image.bindMemory(to: Float.self, capacity: bytes / MemoryLayout<Float>.size)
                } catch {
                    free(image)
                    reason = error.localizedDescription
                }
            } else {
                reason = "The reslice produced no plane."
            }
        }
        let refusal = reason ?? "The colour plane could not be combined."
        MetalPerformanceTrace.recordRefusal("mpr.refusal", reason: refusal)
        recordMetalPlane(reason: refusal, controller: controller)
        return nil
    }

    /// The series fused over this plane, resliced in Metal where VTK
    /// reslices it: on the blending mapper's own grid, origin and sample
    /// distance, with the same camera, slab and mode, from the fused volume in
    /// its own frame. Nil, with the reason, when that plane stays with VTK.
    private func metalFusedPlane(controller: MPRController, vrView: NSView & HorosMPRVRViewMessages,
                                 reason: inout String?) -> MPRFusedPlane? {
        // The fused series converted and validated once (MPRHostVolume); an
        // RGB fused series is refused there, as the 3D view's renderer draws it.
        let volume: MPRHostVolume
        do { volume = try MPRHostVolume.fused(snapshot: vrView.horosMPRFusedVolume() as NSDictionary?) } catch {
            reason = error.localizedDescription
            return nil
        }
        var width = 0, height = 0
        if let geometry = vrView.horosMPRFusedGeometryRefusalWidth(&width, height: &height) {
            reason = geometry
            return nil
        }
        guard let reslicer = controller.metalFusedReslicer(for: volume, reason: &reason) else { return nil }
        var cosines = [Float](repeating: 0, count: 9), corner = [Float](repeating: 0, count: 3)
        vrView.getOrientation(&cosines)
        vrView.getOrigin(&corner, windowCentered: true, sliceMiddle: true, blendedView: true)
        let spacing = vrView.getResolution() * Double(vrView.blendingImageSampleDistance())
        guard let pixels = Self.floats(width * height) else {
            reason = "The fused plane could not be allocated."
            return nil
        }
        do {
            let centre = MPRPlaneRules.pixelCentre(corner: corner, cosines: cosines, spacing: spacing)
            try reslicer.reslice(origin: centre.map { NSNumber(value: $0) }, orientation: Self.numbers(cosines), spacing: spacing,
                                 width: width, height: height, thickness: vrView.getClippingRangeThicknessInMm(),
                                 sampleStep: volume.sampleStep, projection: Int(controller.clippingRangeMode),
                                 background: Double(volume.background), into: pixels)
        } catch {
            free(pixels)
            reason = error.localizedDescription
            return nil
        }
        return MPRFusedPlane(pixels: pixels, width: width, height: height, milliseconds: reslicer.lastMilliseconds)
    }

    // MARK: - What the view takes

    /// Whether the image the last call returned is ARGB bytes, an RGB
    /// volume's plane, rather than floats.
    @objc(horosMPRCopiedImageIsRGB)
    func horosMPRCopiedImageIsRGB() -> Bool { metalPlane.colourImage }

    /// The fused series' plane the last call resliced with it, malloc-owned,
    /// or nil: then the view reslices it with VTK, as it does the plane.
    @objc(horosMPRTakeFusedImageWidth:height:)
    func horosMPRTakeFusedImageWidth(_ width: UnsafeMutablePointer<Int>, height: UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<Float>? {
        let state = metalPlane
        defer { state.fusedPlane = nil }
        guard let plane = state.fusedPlane, let image = plane.pixels else { return nil }
        width.pointee = plane.width
        height.pointee = plane.height
        plane.pixels = nil
        return image
    }

    /// Hands `pix` the cubic display plane of the last reconstruction, or
    /// takes its old one away when the last reconstruction made none.
    @objc(horosMPRAttachDisplayPlaneTo:)
    func horosMPRAttachDisplayPlane(to pix: DCMPix?) {
        let state = metalPlane
        pix?.horosMPRDisplayPixels = state.displayPlane
        state.displayPlane = nil
    }

    /// After VTK's render of a plane in volume rendering mode: whether the
    /// Metal ray cast drew it, as the view's fallback notice and the window's
    /// reason.
    @objc(horosMPRVolumeRendered)
    func horosMPRVolumeRendered() {
        guard let vrView, vrView.horosMPRVolumeMetal() else { return }
        var drawn: ObjCBool = false
        let reason = vrView.horosMPRVolumeMetalReasonDrawn(&drawn)
        vrView.horosSetMPRVolumeMetal(false)
        guard drawn.boolValue else { return }
        if let reason { MetalPerformanceTrace.recordRefusal("mpr.refusal", reason: reason) }
        recordMetalPlane(reason: reason, controller: horosMPRWindowController)
    }
}
