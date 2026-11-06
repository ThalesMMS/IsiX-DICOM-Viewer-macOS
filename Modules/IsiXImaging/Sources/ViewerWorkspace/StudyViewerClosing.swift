//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Window > Close Viewers of This Study: which viewer windows go when the user
// closes the study of the active viewer. A window belongs to a 2D viewer, its
// owner: a 2D viewer owns itself, a 3D or 4D window the 2D viewer it was opened
// from. The study is that owner's. The app describes its windows with these
// values and closes the ones given back, in the order given back.

/// The windows "Close Viewers of This Study" closes.
public enum StudyViewerClosing {

    /// One viewer window, as the rule sees it.
    public struct Window<Owner: Hashable>: Hashable {
        /// The 2D viewer the window belongs to; nil for a window that names none.
        public var owner: Owner?
        /// The Study Instance UID of the owner's series; nil or empty when unknown.
        public var study: String?
        /// Whether the window is the 2D viewer itself, not a 3D or 4D window.
        public var is2D: Bool

        public init(owner: Owner?, study: String?, is2D: Bool) {
            self.owner = owner
            self.study = study
            self.is2D = is2D
        }
    }

    /// The indexes of the `windows` to close for the active 2D viewer `active`
    /// of study `study`: every window whose owner is of that study, and the
    /// active viewer's own windows even when its study is unknown, so that the
    /// command never leaves the viewer it was given open. A window of an
    /// unknown study is not taken for any other study. The 3D and 4D windows
    /// come first, each before the 2D viewer it depends on, in their order.
    public static func windowsToClose<Owner: Hashable>(_ windows: [Window<Owner>], active: Owner, study: String?) -> [Int] {
        let study = known(study)
        let closing = windows.indices.filter { index in
            let window = windows[index]
            guard let owner = window.owner else { return false }
            if owner == active { return true }
            guard let study, let other = known(window.study) else { return false }
            return other == study
        }
        return closing.filter { !windows[$0].is2D } + closing.filter { windows[$0].is2D }
    }

    /// A Study Instance UID that names a study: nil for none or an empty one.
    private static func known(_ study: String?) -> String? {
        guard let study, !study.isEmpty else { return nil }
        return study
    }
}
