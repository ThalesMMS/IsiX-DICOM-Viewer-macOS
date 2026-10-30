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

/// What an MPR window holds for its Metal planes: the reslicers of its
/// volume (one, or three for an RGB volume's channels) and of a fused series,
/// each with the volume it holds, and the outcome of the last plane.
@MainActor final class MPRMetalHostState {
    var reslicer: MPRReslicerBridge?
    var uploaded: MPRHostVolume?
    var fusedReslicer: MPRReslicerBridge?
    var fusedUploaded: MPRHostVolume?
    var colourReslicers: [MPRReslicerBridge]?
    var colourUploaded: MPRHostVolume?
    /// Why the last plane kept the original pixels, or nil.
    var fallbackReason: String?
    /// Wall milliseconds of the last synchronous Metal reslice.
    var lastMilliseconds: Double?
}

/// Settings → 3D holds the MPR's cubic display option. An open MPR follows a
/// change at once: this observer reconstructs its planes. There is one, made
/// on first use and kept for the life of the app; the defaults do not retain
/// it, and it is never removed.
final class MPRCubicDisplayObserver: NSObject, @unchecked Sendable {
    static let preferenceKey = "HorosMPRCubicDisplay"

    private static let shared: MPRCubicDisplayObserver = {
        let observer = MPRCubicDisplayObserver()
        UserDefaults.standard.addObserver(observer, forKeyPath: preferenceKey, options: [], context: nil)
        return observer
    }()

    static func start() { _ = shared }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for window in NSApp.windows {
                    (window.windowController as? MPRController)?.horosMPRReconstructPlanes()
                }
            }
        }
    }
}

/// Metal reconstructs the 3D MPR planes. The window keeps its camera,
/// geometry, ROIs, tools and export; MPRDCMView+MetalPlane.swift reslices
/// each plane. What Metal declines is computed on the CPU and says why. There
/// is no switch to the original renderer. This side holds the reslicers and
/// the volume they reslice.
extension MPRController {

    nonisolated(unsafe) private static var metalHostKey: UInt8 = 0

    var metalHost: MPRMetalHostState {
        if let state = objc_getAssociatedObject(self, &Self.metalHostKey) as? MPRMetalHostState { return state }
        let state = MPRMetalHostState()
        objc_setAssociatedObject(self, &Self.metalHostKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    // MARK: - What the native tools read

    /// Always YES: kept for the native tools that read it. The MPR always asks
    /// Metal, and the CPU plane stands in only for what Metal declines.
    @objc(horosMPRMetalEnabled)
    func horosMPRMetalEnabled() -> Bool {
        MPRCubicDisplayObserver.start()
        return true
    }

    /// Reconstructs the three planes with the current options: the same
    /// sequence the thick-slab mode change uses, a forced camera update that
    /// makes each view reconstruct its plane once.
    @objc(horosMPRReconstructPlanes)
    func horosMPRReconstructPlanes() {
        for view in [mprView1, mprView2, mprView3] {
            guard let view else { continue }
            view.restoreCamera()
            view.camera?.forceUpdate = true
            view.updateViewMPR()
        }
    }

    /// The reason the last reconstruction kept the original pixels, or nil.
    @objc(horosMPRFallbackReason)
    func horosMPRFallbackReason() -> String? { metalHost.fallbackReason }

    /// Whether single planes are drawn with cubic interpolation: the
    /// preference (Settings → 3D), off by default.
    @objc(horosMPRCubicDisplay)
    func horosMPRCubicDisplay() -> Bool {
        UserDefaults.standard.bool(forKey: MPRCubicDisplayObserver.preferenceKey)
    }

    /// Wall milliseconds of the last synchronous Metal reslice, or -1 if none ran.
    @objc(horosMPRLastMilliseconds)
    func horosMPRLastMilliseconds() -> Double { metalHost.lastMilliseconds ?? -1 }

    /// Bytes of the volumes currently on the GPU, the fused one included, or 0.
    @objc(horosMPRVolumeBytes)
    func horosMPRVolumeBytes() -> Int {
        let state = metalHost
        let channels = state.colourReslicers?.reduce(0) { $0 + $1.volumeBytes } ?? 0
        return (state.reslicer?.volumeBytes ?? 0) + (state.fusedReslicer?.volumeBytes ?? 0) + channels
    }

    /// Drops the GPU volume; the next reconstruction uploads it again.
    @objc(horosMPRReleaseVolume)
    func horosMPRReleaseVolume() {
        let state = metalHost
        state.reslicer?.releaseVolume()
        state.fusedReslicer?.releaseVolume()
        state.colourReslicers?.forEach { $0.releaseVolume() }
        state.colourUploaded = nil
        state.uploaded = nil
        state.fusedUploaded = nil
        state.lastMilliseconds = nil
    }

    /// Closing the window frees the GPU volumes and the reslicers.
    @objc(horosMPRWindowWillClose:)
    private func horosMPRWindowWillClose(_ note: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: note.object)
        horosMPRReleaseVolume()
        let state = metalHost
        state.reslicer = nil
        state.fusedReslicer = nil
        state.colourReslicers = nil
    }

    private func observeWindowClose() {
        NotificationCenter.default.addObserver(self, selector: #selector(horosMPRWindowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: window)
    }

    // MARK: - The volume

    /// The viewer's current volume as the MPR reslices it, converted and
    /// validated once (MPRHostVolume): the buffer, its slices, its placement
    /// in the camera's frame, the background and the slab's sample step. Slice
    /// bytes stay in the viewer's order. Nil, with the reason.
    func metalCurrentVolume(reason: inout String?) -> MPRHostVolume? {
        let pix = horosMPRCurrentPixList()
        guard let first = pix?.firstObject as? DCMPix, let pix, let volume = horosMPRCurrentVolumeData() else {
            reason = "The reconstruction has no volume."
            return nil
        }
        guard let step = MPRPlaneRules.sampleStep(sliceInterval: first.sliceInterval, sliceThickness: first.sliceThickness,
                                                  pixelSpacingX: first.pixelSpacingX, pixelSpacingY: first.pixelSpacingY) else {
            reason = "The volume spacing is not usable."
            return nil
        }
        do {
            return try MPRHostVolume.volume(owner: volume, width: first.pwidth, height: first.pheight, depth: pix.count,
                                            voxelToWorld: mprView1?.vrView?.mprVoxelToWorldTransform() as? [NSNumber],
                                            background: first.isRGB ? -1 : (horosMPRHiddenVRController()?.minimumValue() ?? 0),
                                            sampleStep: step, colour: first.isRGB)
        } catch {
            reason = error.localizedDescription
            return nil
        }
    }

    /// The reslicer of a scalar volume, which it holds in the camera's world
    /// frame, its position and orientation included. One upload per volume
    /// buffer: a 4D phase change or a new series hands the MPR another buffer,
    /// which is what invalidates the texture.
    func metalReslicer(for volume: MPRHostVolume, reason: inout String?) -> MPRReslicerBridge? {
        if volume.isColour {
            reason = "RGB volumes keep the original renderer."
            return nil
        }
        let state = metalHost
        let reslicer: MPRReslicerBridge
        if let kept = state.reslicer {
            reslicer = kept
        } else {
            do { reslicer = try MPRReslicerBridge.make() } catch {
                reason = error.localizedDescription
                return nil
            }
            state.reslicer = reslicer
            observeWindowClose()
        }
        if !reslicer.isReady || !volume.isSameVolume(as: state.uploaded) {
            do { try reslicer.upload(volume) } catch {
                state.uploaded = nil
                reason = error.localizedDescription
                return nil
            }
            state.uploaded = volume
        }
        return reslicer
    }

    /// The fused series' own reslicer, uploaded once per buffer and placement.
    func metalFusedReslicer(for volume: MPRHostVolume, reason: inout String?) -> MPRReslicerBridge? {
        let state = metalHost
        let reslicer: MPRReslicerBridge
        if let kept = state.fusedReslicer {
            reslicer = kept
        } else {
            do { reslicer = try MPRReslicerBridge.make() } catch {
                reason = error.localizedDescription
                return nil
            }
            state.fusedReslicer = reslicer
        }
        if !reslicer.isReady || !volume.isSameVolume(as: state.fusedUploaded) {
            do { try reslicer.upload(volume) } catch {
                state.fusedUploaded = nil
                reason = error.localizedDescription
                return nil
            }
            state.fusedUploaded = volume
        }
        return reslicer
    }

    /// An RGB volume's red, green and blue channels, one reslicer each,
    /// uploaded once per volume buffer in the same frame as a scalar volume.
    func metalColourReslicers(for volume: MPRHostVolume, reason: inout String?) -> [MPRReslicerBridge]? {
        let state = metalHost
        let reslicers: [MPRReslicerBridge]
        if let kept = state.colourReslicers {
            reslicers = kept
        } else {
            var made: [MPRReslicerBridge] = []
            for _ in 0..<3 {
                do { made.append(try MPRReslicerBridge.make()) } catch {
                    reason = error.localizedDescription
                    return nil
                }
            }
            reslicers = made
            state.colourReslicers = made
            if state.reslicer == nil { observeWindowClose() }
        }
        if !volume.isSameVolume(as: state.colourUploaded) || !reslicers.allSatisfy(\.isReady) {
            do { try MPRReslicerBridge.uploadColour(volume, into: reslicers) } catch {
                state.colourUploaded = nil
                reason = error.localizedDescription
                return nil
            }
            state.colourUploaded = volume
        }
        return reslicers
    }
}
