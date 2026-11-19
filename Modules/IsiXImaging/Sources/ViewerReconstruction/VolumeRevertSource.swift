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

/// Where Revert Series in a volume rendering window (VR or MIP) takes the
/// volume back from, and whether the window then says that a change stays.
///
/// The window opens on the slices of its 2D viewer and shares their volume.
/// While the 2D viewer shows them as read from their files (it is not
/// post-processed), the 2D viewer reads them again. A change of plane gives
/// the 2D viewer other slices and lets the window keep the former ones: the
/// window then reads them again itself, when they were read from their files
/// (its 2D viewer was not post-processed when it opened, and every slice has
/// a file). Otherwise the copy kept before the first filter brings the volume
/// back, and without one nothing does.
public enum VolumeRevertSource: Equatable, Sendable {
    /// The 2D viewer reads the slices it shows from their files again.
    case viewerReadsFiles
    /// The window reads the slices it kept from their files again.
    case windowReadsFiles
    /// The copy of the volume kept before the first filter.
    case filterCopy
    /// Nothing can bring the volume back.
    case nothing

    /// The source for a window whose 2D viewer shows its slices or not
    /// (`viewerShowsSlices`), is post-processed or not, whose slices were read
    /// from their files (`slicesFromFiles`) and that keeps a copy of the volume
    /// before the first filter or not (`hasFilterCopy`).
    public init(viewerShowsSlices: Bool, viewerPostprocessed: Bool, slicesFromFiles: Bool, hasFilterCopy: Bool) {
        if viewerShowsSlices && !viewerPostprocessed {
            self = .viewerReadsFiles
        } else if !viewerShowsSlices && slicesFromFiles {
            self = .windowReadsFiles
        } else {
            self = hasFilterCopy ? .filterCopy : .nothing
        }
    }

    /// Whether the volume is read from the files: every cut, filter and
    /// correction goes.
    public var readsFiles: Bool {
        self == .viewerReadsFiles || self == .windowReadsFiles
    }

    /// Whether the volume keeps a change after the revert, which the window
    /// then says: none when it is read from the files; with the copy or with
    /// nothing, a change made while there was no copy (a cut or a bone removal
    /// before the first filter, a filter applied without its copy:
    /// `changedWithoutCopy`) or the gantry tilt correction (`tiltCorrected`),
    /// which the copy holds too.
    public func keepsChanges(changedWithoutCopy: Bool, tiltCorrected: Bool) -> Bool {
        readsFiles ? false : changedWithoutCopy || tiltCorrected
    }
}
