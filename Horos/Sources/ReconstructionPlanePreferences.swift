//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import IsiXPreferences

/// What the planes of the MPR read of the preferences of the process graph, each time they draw or export.
extension MPRDCMView {
    /// The annotation level of the viewers (Settings → Viewers).
    nonisolated var preferredAnnotationLevel: Int {
        PreferencesSource.process.preferences[ViewerPreferences.annotations]
    }

    /// Whether the export of the MPR takes all its views in one image.
    nonisolated var exportsAllViewsPreference: Bool {
        PreferencesSource.process.preferences[ReconstructionPreferences.exportIncludesAllViews]
    }
}

/// What the planes of the CPR read of the preferences of the process graph, each time they draw.
extension CPRMPRDCMView {
    /// The annotation level of the viewers (Settings → Viewers).
    nonisolated var preferredAnnotationLevel: Int {
        PreferencesSource.process.preferences[ViewerPreferences.annotations]
    }
}
