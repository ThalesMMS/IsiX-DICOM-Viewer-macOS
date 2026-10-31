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

/// The volume a launch waits for before it opens the database: an external
/// disk that the system has not mounted yet, or one the data folder was moved
/// to (its documents folder names it in DBFOLDER_LOCATION). The app asks the
/// user while it waits; which volume it watches is decided here.
public enum DatabaseVolume {

    /// How long a launch waits for a volume before it goes on without it.
    public static let waitLimit: TimeInterval = 10 * 60

    /// The volume of a path: its first three components ("/Volumes/Name"),
    /// nil for a path with fewer.
    public static func volume(of path: String) -> String? {
        let components = path.components(separatedBy: "/")
        guard components.count >= 3 else { return nil }
        return components[0 ..< 3].joined(separator: "/")
    }

    /// The volume of the database's documents folder to wait for, when the
    /// folder resolved is on a volume or could not be resolved at all. A folder
    /// on a volume that is not mounted resolves to nil, which is exactly the
    /// case to wait for: the volume then comes from the preference itself, the
    /// folder the user chose (location mode 1), so that plugging the disk back
    /// in ends the wait. Nil when there is nothing to wait for.
    public static func documentsVolume(resolved: String?, locationMode: Int, chosenFolder: String?) -> String? {
        if let resolved, !resolved.hasPrefix("/Volumes/") { return nil }
        let configured = locationMode == 1 ? chosenFolder : nil
        let path = (resolved ?? "").isEmpty ? configured : resolved
        guard let path, let volume = volume(of: path), !volume.isEmpty else { return nil }
        return volume
    }

    /// The volume the data folder was moved to (the contents of the documents
    /// folder's DBFOLDER_LOCATION), when it is on one.
    public static func dataVolume(dataFolderLocation: String?) -> String? {
        guard let location = dataFolderLocation, location.hasPrefix("/Volumes/") else { return nil }
        return volume(of: location)
    }

    /// What a launch does while it waits, at each turn of the panel's session.
    public enum WaitStep: Equatable, Sendable {
        /// Quit was chosen.
        case quit
        /// The wait ends: Continue was chosen, the volume appeared, or the time ran out.
        case proceed(timedOut: Bool)
        /// Still waiting.
        case wait
    }

    /// The next step from the panel's answer (`quitResponse`, `continueResponse`
    /// or anything else while it is up), whether the volume is there now, and
    /// the time left.
    public static func step(response: Int, quitResponse: Int, continueResponse: Int, volumeExists: Bool,
                            now: TimeInterval, deadline: TimeInterval) -> WaitStep {
        if response == quitResponse { return .quit }
        if response == continueResponse || volumeExists { return .proceed(timedOut: false) }
        if now > deadline { return .proceed(timedOut: true) }
        return .wait
    }
}
