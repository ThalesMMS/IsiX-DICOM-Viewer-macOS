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

/// Where the running copy of the application is, and where a move would put it.
public enum ApplicationLocation {
    /// Gatekeeper runs a quarantined copy opened where it was downloaded
    /// from a random read-only folder, .../AppTranslocation/<UUID>/d/, not
    /// from where the user put it.
    public static func isTranslocated(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains("AppTranslocation")
    }

    /// Inside the bundle of another application.
    public static func isNested(_ path: String) -> Bool {
        ((path as NSString).deletingLastPathComponent as NSString).pathComponents.contains { $0.hasSuffix(".app") }
    }

    /// Inside one of the Applications folders, or in any folder named
    /// Applications: compared by whole components, so "ApplicationsFake" is not one.
    public static func isInstalled(_ path: String, applicationDirectories: [String]) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return applicationDirectories.contains { standardized.hasPrefix(($0 as NSString).standardizingPath + "/") }
            || ((standardized as NSString).deletingLastPathComponent as NSString).pathComponents.contains("Applications")
    }

    /// The Applications folder in the user's home when it already holds an
    /// application, the computer's otherwise.
    public static func preferredDirectory(user: String?, userHasApplications: Bool, local: String) -> String {
        if let user, userHasApplications { return user }
        return local
    }
}

/// Whether the application offers to move itself to Applications.
public enum MoveOffer {
    public enum Reason: Equatable, Sendable {
        /// The App Store and TestFlight install the application themselves.
        case appStore
        /// The user asked not to be asked again.
        case suppressed
        /// An offer is already on screen.
        case inProgress
        /// The copy already runs from an Applications folder.
        case installed
        /// The copy runs translocated and the folder it really is in is unknown.
        case translocatedOriginalUnknown
    }

    public enum Decision: Equatable, Sendable {
        /// Offer to move the copy at this path: the folder it really is in,
        /// even when Gatekeeper runs it translocated.
        case offer(source: String)
        case skip(Reason)
    }

    /// `runningPath` is the bundle that runs; `originalPath`, for a
    /// translocated one, is where it really is.
    public static func decide(isAppStore: Bool, suppressed: Bool, inProgress: Bool,
                              runningPath: String, originalPath: String?,
                              applicationDirectories: [String]) -> Decision {
        if isAppStore { return .skip(.appStore) }
        if inProgress { return .skip(.inProgress) }
        if suppressed { return .skip(.suppressed) }
        let source: String
        if ApplicationLocation.isTranslocated(runningPath) {
            guard let originalPath else { return .skip(.translocatedOriginalUnknown) }
            source = originalPath
        } else {
            source = runningPath
        }
        // A copy nested in another application is moved out of it even there.
        if ApplicationLocation.isInstalled(source, applicationDirectories: applicationDirectories)
            && !ApplicationLocation.isNested(source) {
            return .skip(.installed)
        }
        return .offer(source: source)
    }
}
