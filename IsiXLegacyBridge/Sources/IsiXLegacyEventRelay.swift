//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The database's events of the plugin API, for the legacy notifications
// OsirixAddToDBNotification and OsirixAddToDBCompleteNotification: the kit's
// Objective-C (IsiXLegacyNotifications.m) posts them in the plugin's
// notification center with the kit's DicomImage objects. Nothing is asked of
// the application until the plugin observes one of the two names.

import AppKit
import IsiXPluginKit

/// What the relay hands the Objective-C poster: the kind of event and its
/// details in Objective-C types.
@objc protocol IsiXLegacyEventPoster: NSObjectProtocol {
    /// `kind`: imagesAdded (images: records of the legacy database, perAET:
    /// AE title → SOP Instance UIDs, complete).
    @objc(isixPostEvent:info:) func isixPost(event kind: String, info: [String: Any])
}

@MainActor
@objc final class IsiXLegacyEventRelay: NSObject {
    /// The names of Notifications.h this relay feeds.
    static let names: Set<String> = ["OsirixAddToDBNotification", "OsirixAddToDBCompleteNotification"]

    private static var observation: IsiXObservation?
    private static weak var poster: IsiXLegacyEventPoster?

    /// The plugin observes `name` in its notification center; the first of
    /// the database's names starts the observation of the plugin API.
    static func notificationObserved(_ name: String) {
        guard observation == nil, names.contains(name), let context = IsiXLegacyState.shared.context else { return }
        observation = try? context.observe(.imagesAdded) { event in IsiXLegacyEventRelay.relay(event) }
    }

    static func stop() {
        observation = nil
        poster = nil
    }

    /// The Objective-C poster, set when the filter starts.
    @objc nonisolated static func setPoster(_ poster: IsiXLegacyEventPoster?) {
        IsiXLegacyOnMain { Self.poster = poster }
    }

    private static func relay(_ event: IsiXEvent) {
        guard let poster, case .imagesAdded(let added) = event else { return }
        poster.isixPost(event: "imagesAdded", info: [
            "images": added.images.map(IsiXLegacyDatabaseBridge.record),
            "perAET": added.sopInstanceUIDsByCallingAETitle,
            "complete": added.isComplete,
        ])
    }
}
