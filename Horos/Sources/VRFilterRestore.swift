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

/// What the 3D window does with the 2D series when it closes.
@objc(HorosVRFilterCloseAction)
public enum VRFilterCloseAction: Int {
    /// Nothing to undo, or the 2D viewer is closing too.
    case none
    /// Only filters changed the volume: put back the copy.
    case restore
    /// A cut followed the first filter: restoring would also drop that cut.
    case ask
}

/// The volume of a volume rendering window as it was before its first
/// convolution filter.
///
/// The 3D window has no volume of its own: it renders the float buffer of the
/// 2D viewer it was opened from, and a convolution filter applied there is
/// written into that buffer, so the 2D series showed it too and kept it after
/// the 3D window had closed. Scissors and bone removal write into the same
/// buffer on purpose, and the 2D series keeps those cuts.
///
/// The copy is exact (float for float) and taken only when a filter is first
/// applied, so a window that never filters costs no memory. A cut made after
/// that first filter is recorded, because putting the copy back would undo it
/// as well.
@objc(HorosVRFilterRestore)
public final class VRFilterRestore: NSObject {
    private var copies: [UnsafeMutableRawPointer] = []
    private var lengths: [Int] = []

    /// A scissors or bone removal cut was made after the copy was taken.
    @objc public private(set) var cutAfterFilter = false

    /// Copies each volume (one per movie frame of a 4D series), or fails
    /// without keeping anything when the memory for one of them is missing.
    @objc(initWithVolumes:)
    public init?(volumes: [NSData]) {
        super.init()
        for volume in volumes {
            let length = volume.length
            guard let copy = malloc(max(length, 1)) else {
                release()
                return nil
            }
            if length > 0 {
                memcpy(copy, volume.bytes, length)
            }
            copies.append(copy)
            lengths.append(length)
        }
    }

    deinit {
        release()
    }

    private func release() {
        copies.forEach { free($0) }
        copies = []
        lengths = []
    }

    @objc public var volumeCount: Int { copies.count }

    @objc public func noteCut() {
        cutAfterFilter = true
    }

    /// Writes the copies back into the volumes they were taken from and
    /// returns how many were written. A volume whose size changed since, or
    /// one past those copied, is left alone.
    @objc(restoreInto:)
    @discardableResult
    public func restore(into volumes: [NSData]) -> Int {
        var restored = 0
        for (index, volume) in volumes.enumerated() where index < copies.count {
            guard volume.length == lengths[index] else { continue }
            if volume.length > 0 {
                memcpy(UnsafeMutableRawPointer(mutating: volume.bytes), copies[index], volume.length)
            }
            restored += 1
        }
        return restored
    }

    @objc(closeActionWithCopy:cutAfterFilter:viewerClosing:)
    public static func closeAction(hasCopy: Bool, cutAfterFilter: Bool, viewerClosing: Bool) -> VRFilterCloseAction {
        if !hasCopy || viewerClosing {
            return .none
        }
        return cutAfterFilter ? .ask : .restore
    }
}
