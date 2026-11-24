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

/// The volumes a medium is being written to. The list of sources reads every
/// volume that is mounted or renamed and asks what to do with one that holds
/// studies; a volume the application is writing is renamed at the end of the
/// copy, with its studies on it, and is not a disc that arrived. It is followed
/// here through its renames until it is unmounted or the writing ends.
public struct VolumesBeingWritten: Sendable, Equatable {
    /// The path each volume has now, by the path it had when its writing began.
    private var current: [String: String] = [:]

    public init() {}

    /// The writing of the volume at `path` begins.
    public mutating func begin(_ path: String) {
        current[path] = path
    }

    /// Whether the volume at `path` is one being written.
    public func contains(_ path: String?) -> Bool {
        guard let path else { return false }
        return current.values.contains(path)
    }

    /// A volume was renamed: one being written stays so under its new path.
    public mutating func renamed(from oldPath: String?, to path: String?) {
        guard let oldPath, let path else { return }
        for (began, now) in current where now == oldPath {
            current[began] = path
        }
    }

    /// A volume was unmounted: it is not being written any more.
    public mutating func unmounted(_ path: String?) {
        guard let path else { return }
        current = current.filter { $0.value != path }
    }

    /// The writing ended, whatever became of it: no volume is being written.
    public mutating func end() {
        current.removeAll()
    }
}
