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

/// Where a 3D viewer keeps its Metal volume renderers and what they last did:
/// the image's and a fused series' each have a renderer, the volume it holds,
/// the reason it last declined and the milliseconds of its last render. They
/// hang on the VRController; the reasons are written by its view too.
enum VolumeMetalSlots {
    nonisolated(unsafe) static var renderer: UInt8 = 0
    nonisolated(unsafe) static var uploaded: UInt8 = 0
    nonisolated(unsafe) static var reason: UInt8 = 0
    nonisolated(unsafe) static var milliseconds: UInt8 = 0
    nonisolated(unsafe) static var fusedRenderer: UInt8 = 0
    nonisolated(unsafe) static var fusedUploaded: UInt8 = 0
    nonisolated(unsafe) static var fusedReason: UInt8 = 0
    nonisolated(unsafe) static var fusedMilliseconds: UInt8 = 0

    static func get(_ object: AnyObject, _ key: UnsafeRawPointer) -> Any? { objc_getAssociatedObject(object, key) }

    static func set(_ object: AnyObject, _ key: UnsafeRawPointer, _ value: Any?, copy: Bool = false) {
        objc_setAssociatedObject(object, key, value, copy ? .OBJC_ASSOCIATION_COPY_NONATOMIC : .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func reasonKey(fused: Bool) -> UnsafeRawPointer { fused ? key(&fusedReason) : key(&reason) }
    static func key(_ slot: UnsafeMutablePointer<UInt8>) -> UnsafeRawPointer { UnsafeRawPointer(slot) }
}

/// Metal volume rendering in the host's 3D viewer. The viewer keeps the
/// volume, the VTK camera, the transfer function, presets, tools, export and
/// every notification; its view reads that state as numbers
/// (VRView+VolumeHost.swift) and the renderers here draw it with
/// `HorosVolumeRenderer`. Each native mapper - the volume's and a fused
/// series' - fills its own ray-cast image in Metal, and VTK composes them;
/// unsupported cases use the CPU with a visible reason. Main thread only.
extension VRController {

    /// The volume of the current movie frame and its slices.
    func horosVolumePixList() -> NSArray? { curPixList() as NSArray? }

    /// The state the renderer consumes, or a dictionary with an `error` entry.
    @objc func horosVolumeSnapshot() -> NSDictionary { volumeView!.horosVolumeSnapshot() }

    /// Renders the current state at the given size (BGRA, row 0 at the top).
    /// `scalarOut`, when given, receives the projected scalar for MIP/MinIP/mean.
    @objc(horosVolumeMetalRenderWithWidth:height:scalarOut:error:)
    func horosVolumeMetalRender(width: Int, height: Int, scalarOut: NSMutableData?) throws -> NSData {
        try horosVolumeMetalRender(camera: nil, near: 0, far: -1, width: width, height: height, scalarOut: scalarOut)
    }

    /// Same state, explicit camera: position(3), focal(3), viewUp(3), parallel,
    /// parallelScale, viewAngle in the volume's millimetre frame, and a clipping
    /// range (far < 0 for none). Used to reproduce the exact sub-rectangle VTK's
    /// ray-cast image covers, for the numeric comparison.
    @objc(horosVolumeMetalRenderWithCamera:near:far:width:height:scalarOut:error:)
    func horosVolumeMetalRender(camera: [NSNumber]?, near: Double, far: Double, width: Int, height: Int,
                                scalarOut: NSMutableData?) throws -> NSData {
        try horosVolumeMetalRender(camera: camera, near: near, far: far, width: width, height: height, imageRegion: [],
                                   scalarOut: scalarOut)
    }

    @objc(horosVolumeMetalRenderWithCamera:near:far:width:height:imageRegion:scalarOut:error:)
    func horosVolumeMetalRender(camera: [NSNumber]?, near: Double, far: Double, width: Int, height: Int,
                                imageRegion: [NSNumber], scalarOut: NSMutableData?) throws -> NSData {
        try horosVolumeMetalRender(camera: camera, near: near, far: far, width: width, height: height, imageRegion: imageRegion,
                                   geometryDepth: nil, scalarOut: scalarOut)
    }

    @objc(horosVolumeMetalRenderWithCamera:near:far:width:height:imageRegion:geometryDepth:scalarOut:error:)
    func horosVolumeMetalRender(camera: [NSNumber]?, near: Double, far: Double, width: Int, height: Int,
                                imageRegion: [NSNumber], geometryDepth: Data?, scalarOut: NSMutableData?) throws -> NSData {
        let snapshotFrom = MetalPerformanceTrace.hostTime()
        var snapshot = horosVolumeSnapshot()
        MetalPerformanceTrace.recordHost("vr.host_snapshot", startedAt: snapshotFrom)
        if let camera, camera.count == 12, snapshot["error"] == nil {
            let overridden = NSMutableDictionary(dictionary: snapshot)
            overridden["camera"] = camera
            overridden["near"] = near
            overridden["far"] = far
            snapshot = overridden
        }
        return try horosVolumeMetalRender(snapshot, fused: false, width: width, height: height, imageRegion: imageRegion,
                                          geometryDepth: geometryDepth, scalarOut: scalarOut)
    }

    @objc(horosFusedVolumeMetalRenderSnapshot:width:height:imageRegion:geometryDepth:scalarOut:error:)
    func horosFusedVolumeMetalRender(snapshot: NSDictionary, width: Int, height: Int, imageRegion: [NSNumber],
                                     geometryDepth: Data?, scalarOut: NSMutableData?) throws -> NSData {
        try horosVolumeMetalRender(snapshot, fused: true, width: width, height: height, imageRegion: imageRegion,
                                   geometryDepth: geometryDepth, scalarOut: scalarOut)
    }

    /// Renders one volume's snapshot with its own renderer: the image's, or the
    /// fused series', each holding its own volume on the GPU.
    @objc(horosVolumeMetalRender:fused:width:height:imageRegion:geometryDepth:scalarOut:error:)
    func horosVolumeMetalRender(_ snapshot: NSDictionary, fused: Bool, width: Int, height: Int, imageRegion: [NSNumber],
                                geometryDepth: Data?, scalarOut: NSMutableData?) throws -> NSData {
        try horosVolumeMetalRender(snapshot, fused: fused, width: width, height: height, imageRegion: imageRegion,
                                   geometryDepth: geometryDepth, scalarOut: scalarOut, forVTK: false)
    }

    @objc(horosVolumeMetalRender:fused:width:height:imageRegion:geometryDepth:scalarOut:forVTK:error:)
    func horosVolumeMetalRender(_ snapshot: NSDictionary, fused: Bool, width: Int, height: Int, imageRegion: [NSNumber],
                                geometryDepth: Data?, scalarOut: NSMutableData?, forVTK: Bool) throws -> NSData {
        let rendererSlot = fused ? VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer) : VolumeMetalSlots.key(&VolumeMetalSlots.renderer)
        let uploadedSlot = fused ? VolumeMetalSlots.key(&VolumeMetalSlots.fusedUploaded) : VolumeMetalSlots.key(&VolumeMetalSlots.uploaded)
        var reason = snapshot["error"] as? String
        var renderer = VolumeMetalSlots.get(self, rendererSlot) as? VolumeRendererBridge
        if reason == nil, renderer == nil {
            do {
                let made = try VolumeRendererBridge.make()
                VolumeMetalSlots.set(self, rendererSlot, made)
                renderer = made
            } catch {
                reason = (error as NSError).localizedDescription
            }
        }
        if reason == nil, let renderer {
            let volume = snapshot["volume"] as? NSData
            let w = (snapshot["volumeWidth"] as? NSNumber)?.intValue ?? 0
            let h = (snapshot["volumeHeight"] as? NSNumber)?.intValue ?? 0
            let d = (snapshot["volumeDepth"] as? NSNumber)?.intValue ?? 0
            let expected = VolumeAllocation.byteCount(width: w, height: h, slices: d, bytesPerVoxel: 4)
            if expected == 0 || (volume?.length ?? 0) < expected {
                reason = "The volume bytes do not match the slice list."
            } else if let volume, VolumeMetalSlots.get(self, uploadedSlot) as? NSData !== volume || !renderer.isReady {
                let slices = volume.length == expected ? volume
                    : NSData(bytesNoCopy: UnsafeMutableRawPointer(mutating: volume.bytes), length: expected, freeWhenDone: false)
                let transform = snapshot["transform"] as? [NSNumber] ?? []
                do {
                    if (snapshot["colourVolume"] as? NSNumber)?.boolValue == true {
                        try renderer.uploadColourVolume(slices, width: w, height: h, depth: d, transform: transform)
                    } else {
                        try renderer.uploadVolume(slices, width: w, height: h, depth: d, transform: transform)
                    }
                    VolumeMetalSlots.set(self, uploadedSlot, volume)
                } catch {
                    VolumeMetalSlots.set(self, uploadedSlot, nil)
                    reason = (error as NSError).localizedDescription
                }
            }
        }
        var bytes: NSData?
        if reason == nil, let renderer {
            func number(_ key: String) -> Double { (snapshot[key] as? NSNumber)?.doubleValue ?? 0 }
            var failure: Error?
            do {
                bytes = try renderer.render(camera: snapshot["camera"] as? [NSNumber] ?? [], near: number("near"), far: number("far"),
                                            level: number("level"), width: number("width"), clut: snapshot["clut"] as? NSData ?? NSData(),
                                            opacityPoints: snapshot["opacity"] as? [NSNumber] ?? [],
                                            opacityTable: snapshot["opacityTable"] as? NSData,
                                            mode: (snapshot["mode"] as? NSNumber)?.intValue ?? 0,
                                            shading: snapshot["shading"] as? [NSNumber] ?? [], crop: [],
                                            clippingPlanes: snapshot["clippingPlanes"] as? [NSNumber] ?? [],
                                            width: width, height: height, sampleStep: number("sampleStep"),
                                            scalarBackground: number("scalarBackground"),
                                            anchoredProjection: (snapshot["anchoredProjection"] as? NSNumber)?.boolValue ?? false,
                                            imageRegion: imageRegion, geometryDepth: geometryDepth, scalarOut: scalarOut)
            } catch {
                failure = error
            }
            // An RGB volume's projection comes back as three values a pixel; its
            // public BGRA result is painted here. The VTK hook paints the same
            // components once, directly into its 15-bit picture instead.
            let pixels = width * height
            if !forVTK, bytes != nil, (snapshot["colourVolume"] as? NSNumber)?.boolValue == true,
               (snapshot["mode"] as? NSNumber)?.intValue ?? 0 != 0, let scalarOut,
               scalarOut.length == pixels * 3 * MemoryLayout<Float>.size {
                let picture = MPRColourPlane.picture(components: scalarOut, count: pixels,
                                                     tables: snapshot["componentTables"] as? [NSDictionary] ?? [])
                if let picture {
                    let bgra = NSMutableData(length: pixels * 4)!
                    let rgba = picture.bytes.assumingMemoryBound(to: UInt16.self)
                    let out = bgra.mutableBytes.assumingMemoryBound(to: UInt8.self)
                    for i in 0..<pixels {
                        out[4 * i] = UInt8(truncatingIfNeeded: rgba[4 * i + 2] >> 7)
                        out[4 * i + 1] = UInt8(truncatingIfNeeded: rgba[4 * i + 1] >> 7)
                        out[4 * i + 2] = UInt8(truncatingIfNeeded: rgba[4 * i] >> 7)
                        out[4 * i + 3] = 255
                    }
                    bytes = bgra
                } else {
                    // Without a picture there are no bytes: the reason below is
                    // the render's, which succeeded.
                    bytes = nil
                }
            }
            if bytes != nil {
                VolumeMetalSlots.set(self, fused ? VolumeMetalSlots.key(&VolumeMetalSlots.fusedMilliseconds)
                                                 : VolumeMetalSlots.key(&VolumeMetalSlots.milliseconds), renderer.lastMilliseconds as NSNumber)
            } else {
                reason = failure.map { ($0 as NSError).localizedDescription } ?? "The render produced no image."
            }
        }
        VolumeMetalSlots.set(self, VolumeMetalSlots.reasonKey(fused: fused), reason, copy: true)
        guard let bytes else {
            throw NSError(domain: "HorosVolumeMetal", code: 1, userInfo: [NSLocalizedDescriptionKey: reason ?? ""])
        }
        return bytes
    }

    /// The reason the last render declined, or nil.
    @objc func horosVolumeMetalFallbackReason() -> String? {
        VolumeMetalSlots.get(self, VolumeMetalSlots.reasonKey(fused: false)) as? String
    }

    /// The same for the fused series' volume.
    @objc func horosFusedVolumeMetalFallbackReason() -> String? {
        VolumeMetalSlots.get(self, VolumeMetalSlots.reasonKey(fused: true)) as? String
    }

    /// Milliseconds of the last GPU render, or -1.
    @objc func horosVolumeMetalLastMilliseconds() -> Double {
        (VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.milliseconds)) as? NSNumber)?.doubleValue ?? -1
    }

    /// The same for the fused series' volume.
    @objc func horosFusedVolumeMetalLastMilliseconds() -> Double {
        (VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedMilliseconds)) as? NSNumber)?.doubleValue ?? -1
    }

    /// Bytes of the volumes on the GPU, the image's and a fused series', or 0.
    @objc func horosVolumeMetalBytes() -> Int {
        let renderer = VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.renderer)) as? VolumeRendererBridge
        let fused = VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer)) as? VolumeRendererBridge
        return (renderer?.volumeBytes ?? 0) + (fused?.volumeBytes ?? 0)
    }

    /// Drops the GPU volumes; the next render re-uploads.
    @objc func horosVolumeMetalRelease() {
        (VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.renderer)) as? VolumeRendererBridge)?.releaseVolume()
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.uploaded), nil)
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.milliseconds), nil)
        horosFusedVolumeMetalRelease()
    }

    /// Drops the fused series' renderer and its volume; a later fusion makes a
    /// new one.
    @objc func horosFusedVolumeMetalRelease() {
        guard let renderer = VolumeMetalSlots.get(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer)) as? VolumeRendererBridge
        else { return }
        renderer.releaseVolume()
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer), nil)
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedUploaded), nil)
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedMilliseconds), nil)
        VolumeMetalSlots.set(self, VolumeMetalSlots.reasonKey(fused: true), nil, copy: true)
    }

    /// Drops the GPU volumes and the renderers themselves, when the window
    /// closes. Sent by -[VRController windowWillClose:]: the renderers are not
    /// dropped from an observer of the window's NSWindowWillCloseNotification,
    /// because the controller is the window's delegate, and removing its
    /// registration for that notification also removed the one AppKit made for
    /// -windowWillClose:, which then never ran and never released the controller
    /// and its volume.
    @objc func horosVolumeMetalDropRenderers() {
        horosVolumeMetalRelease()
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.renderer), nil)
        VolumeMetalSlots.set(self, VolumeMetalSlots.key(&VolumeMetalSlots.fusedRenderer), nil)
    }
}
