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

import Foundation
import simd

/// One volume the 3D MPR reslices: the viewer's scalar volume, the series
/// fused over it, or an RGB volume's ARGB bytes. `MPRHostBridge.m` converts
/// what the host hands over into this once per plane, and nothing after the
/// conversion reads a dictionary key or a raw buffer length again.
///
/// The conversion checks presence, type, extent, byte count (the host's buffer
/// may be longer than its slices, never shorter), finite values and a usable
/// geometry before any byte is read. Only then is the buffer cut to the bytes
/// the slices use, without a copy: `voxels` and `slices` point into `owner`
/// and keep it alive, so a reslicer holding the uploaded volume never holds a
/// pointer whose lifetime nobody owns.
///
/// Immutable; built and read on the main thread, where the MPR reconstructs.
@objc(HorosMPRVolume)
public final class MPRHostVolume: NSObject {
    /// The buffer the bytes belong to: the viewer's volume, retained.
    @objc public let owner: NSData
    @objc public let width: Int, height: Int, depth: Int
    /// 4 bytes a voxel: a float, or an ARGB pixel for a colour volume.
    @objc public let bytesPerVoxel: Int
    @objc public let rowBytes: Int, sliceBytes: Int, byteCount: Int
    /// Column-major: `voxelToWorld * (i, j, k, 1)` is the centre of voxel (i, j, k), in millimetres.
    public let voxelToWorld: simd_float4x4
    /// The same matrix as the host gave it, column by column.
    @objc public let transform: [NSNumber]
    /// What a ray that misses the volume reads.
    @objc public let background: Float
    /// The slab's distance between samples, in millimetres.
    @objc public let sampleStep: Double
    /// The series fused over the plane rather than the viewer's own.
    @objc public let isFused: Bool
    /// ARGB bytes, resliced channel by channel.
    @objc public let isColour: Bool
    /// The first `byteCount` bytes of `owner`, not copied; holds `owner`.
    public let voxels: Data

    private init(owner: NSData, width: Int, height: Int, depth: Int, byteCount: Int, voxelToWorld: simd_float4x4,
                 transform: [NSNumber], background: Float, sampleStep: Double, fused: Bool, colour: Bool) {
        self.owner = owner
        self.width = width; self.height = height; self.depth = depth
        bytesPerVoxel = 4; rowBytes = width * 4; sliceBytes = width * height * 4
        self.byteCount = byteCount
        self.voxelToWorld = voxelToWorld; self.transform = transform
        self.background = background; self.sampleStep = sampleStep
        isFused = fused; isColour = colour
        // Validated above: owner holds at least byteCount bytes. The
        // deallocator does not free them; it keeps their owner until the view goes.
        voxels = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: owner.bytes), count: byteCount,
                      deallocator: .custom { _, _ in withExtendedLifetime(owner) {} })
        super.init()
    }

    /// The same bytes as `voxels`, for the Objective-C that splits colour channels.
    @objc public var slices: NSData { voxels as NSData }

    /// The viewer's volume, or an RGB volume's ARGB bytes. Nil, with the
    /// reason in `error`, when anything is missing, short or not finite.
    @objc(volumeWithOwner:width:height:depth:voxelToWorld:background:sampleStep:colour:error:)
    public static func volume(owner: NSData?, width: Int, height: Int, depth: Int, voxelToWorld: [NSNumber]?,
                              background: Float, sampleStep: Double, colour: Bool) throws -> MPRHostVolume {
        try make(owner: owner, width: width, height: height, depth: depth, transform: voxelToWorld,
                 background: background, sampleStep: sampleStep, fused: false, colour: colour)
    }

    /// The fused series from `-[VRView horosMPRFusedVolume]`: its `volume`,
    /// `width`, `height`, `depth`, column-major `transform`, `background` and
    /// `sampleStep`, or its `error`. The dictionary also feeds the 3D view's
    /// renderer, so it keeps its shape; the MPR reads it here only.
    @objc(fusedVolumeFromSnapshot:error:)
    public static func fused(snapshot: NSDictionary?) throws -> MPRHostVolume {
        guard let snapshot else { throw refusal("The fused series has no volume yet.") }
        if let error = snapshot["error"] {
            throw refusal((error as? String) ?? "The fused series has no volume yet.")
        }
        func number(_ key: String) throws -> NSNumber {
            guard let value = snapshot[key] as? NSNumber else { throw refusal("The fused volume has no valid \(key).") }
            return value
        }
        func count(_ key: String) throws -> Int {
            let value = try number(key).doubleValue
            guard value.isFinite, value.rounded() == value, value >= 1, value <= Double(Int32.max)
            else { throw refusal("The fused volume has no valid \(key).") }
            return Int(value)
        }
        // The fused reslice has no colour path; the 3D view's renderer draws an RGB fused series (#725).
        if snapshot["colour"] != nil, try number("colour").boolValue {
            throw refusal("An RGB fused series keeps the original renderer.")
        }
        guard let owner = snapshot["volume"] as? NSData else { throw refusal("The fused volume has no valid volume.") }
        guard let transform = snapshot["transform"] as? [NSNumber] else { throw refusal("The fused volume has no valid transform.") }
        return try make(owner: owner, width: count("width"), height: count("height"), depth: count("depth"),
                        transform: transform, background: number("background").floatValue,
                        sampleStep: number("sampleStep").doubleValue, fused: true, colour: false)
    }

    private static func make(owner: NSData?, width: Int, height: Int, depth: Int, transform: [NSNumber]?,
                             background: Float, sampleStep: Double, fused: Bool, colour: Bool) throws -> MPRHostVolume {
        let subject = fused ? "The fused volume" : "The volume"
        guard let owner else { throw refusal(fused ? "The fused series has no volume yet." : "The reconstruction has no volume.") }
        guard width > 0, height > 0, depth > 0 else { throw refusal("\(subject) has no extent.") }
        let byteCount = VolumeAllocation.byteCount(width: width, height: height, slices: depth, bytesPerVoxel: 4)
        // The viewer's buffer can be larger than the slices it holds; VTK
        // imports the first width × height × depth values from it, and so does
        // the engine. A shorter one is refused; an overflow counts as Int.max.
        guard byteCount > 0, byteCount < Int.max, owner.length >= byteCount else {
            throw refusal(fused ? "The fused volume bytes do not match its slices." : "The volume bytes do not match the slice list.")
        }
        guard let transform, transform.count == 16 else { throw refusal("\(subject) transform is unavailable.") }
        let m = transform.map { $0.floatValue }
        guard m.allSatisfy({ $0.isFinite }) else { throw refusal("\(subject) transform is not finite.") }
        let matrix = simd_float4x4(columns: (SIMD4(m[0], m[1], m[2], m[3]), SIMD4(m[4], m[5], m[6], m[7]),
                                             SIMD4(m[8], m[9], m[10], m[11]), SIMD4(m[12], m[13], m[14], m[15])))
        let linear = simd_float3x3(SIMD3(m[0], m[1], m[2]), SIMD3(m[4], m[5], m[6]), SIMD3(m[8], m[9], m[10]))
        guard abs(linear.determinant) > 1e-12 else { throw refusal("\(subject) geometry is degenerate; no plane can be resliced from it.") }
        guard background.isFinite else { throw refusal("\(subject) background is not finite.") }
        guard sampleStep.isFinite, sampleStep > 0 else { throw refusal("\(subject) spacing is not usable.") }
        return MPRHostVolume(owner: owner, width: width, height: height, depth: depth, byteCount: byteCount,
                             voxelToWorld: matrix, transform: transform, background: background,
                             sampleStep: sampleStep, fused: fused, colour: colour)
    }

    /// Whether a reslicer that holds `uploaded` already holds this volume: the
    /// same buffer, extent, kind and placement. A 4D phase change or a new
    /// series hands the host a different buffer, which invalidates the upload.
    @objc(isSameVolumeAs:)
    public func isSameVolume(as uploaded: MPRHostVolume?) -> Bool {
        guard let uploaded else { return false }
        return uploaded.owner === owner && uploaded.width == width && uploaded.height == height && uploaded.depth == depth
            && uploaded.isColour == isColour && uploaded.voxelToWorld == voxelToWorld
    }

    static func refusal(_ reason: String) -> NSError { ResliceFailure.geometry(reason).nsError }
}

extension MPRReslicerBridge {
    /// Uploads a scalar volume, the viewer's or the fused one, from its
    /// validated conversion: the engine reads `voxels`, which keeps its owner.
    @objc(uploadVolume:error:)
    public func upload(_ volume: MPRHostVolume) throws {
        guard !volume.isColour else { throw MPRHostVolume.refusal("An RGB volume is uploaded channel by channel.") }
        do {
            try engine.upload(ResliceVolume(width: volume.width, height: volume.height, depth: volume.depth,
                                            voxels: volume.voxels, voxelToWorld: volume.voxelToWorld))
        } catch let failure as ResliceFailure { throw failure.nsError }
    }

    /// Uploads an RGB volume's red, green and blue channels (#724), one to each
    /// of three reslicers, with the volume's placement.
    @objc(uploadColourVolume:into:error:)
    public static func uploadColour(_ volume: MPRHostVolume, into reslicers: [MPRReslicerBridge]) throws {
        guard volume.isColour, reslicers.count == 3 else { throw MPRHostVolume.refusal("A colour plane needs three channels.") }
        guard let channels = MPRColourPlane.channels(fromARGB: volume.slices, width: volume.width,
                                                     rows: volume.height * volume.depth), channels.count == 3
        else { throw MPRHostVolume.refusal("The colour channels could not be separated.") }
        for (reslicer, channel) in zip(reslicers, channels) {
            do {
                try reslicer.engine.upload(ResliceVolume(width: volume.width, height: volume.height, depth: volume.depth,
                                                         voxels: channel as Data, voxelToWorld: volume.voxelToWorld))
            } catch let failure as ResliceFailure { throw failure.nsError }
        }
    }
}
