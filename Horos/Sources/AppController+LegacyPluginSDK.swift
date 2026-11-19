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

/// Selectors of the former Horos/OsiriX plug-in SDK on the application's
/// controller. Each forwards to the type that does the work today.
extension AppController {
    /// The database window's screen, when a screen is reserved for it.
    @objc(dbScreen) func legacyDatabaseScreen() -> NSScreen? { windowArranger.databaseScreen() }

    /// The item of the Help menu of the 32-bit application; there is none.
    @IBAction @objc(osirix64bit:) func legacy64bit(_ sender: Any?) {
        FormerSDKFacade.inert("AppController", "-osirix64bit:", because: "the application is 64-bit only")
    }

    /// The timer body of the preferences' check: answers what changed now.
    @objc(runPreferencesUpdateCheck:) func legacyPreferencesCheck(_ timer: Timer?) { preferenceChanges.check() }

    // The former bodies of the listeners' threads, from any thread: the
    // listener starts if it is stopped, never a second one, and the call returns.
    @objc(startSTORESCP:) nonisolated func legacyStartListener(_ sender: Any?) { dicomListener.startIfStopped(tls: false) }
    @objc(startSTORESCPTLS:) nonisolated func legacyStartTLSListener(_ sender: Any?) { dicomListener.startIfStopped(tls: true) }

    /// Tiles the windows of the controllers given; the series lists follow the preference.
    @objc(tileWindows:windows:display2DViewerToolbar:displayThumbnailsList:) func legacyTile(_ sender: Any?, windows: [Any]?, display2DViewerToolbar: Bool, displayThumbnailsList: Bool) {
        windowArranger.tileWindows(sender: sender, controllers: (windows ?? []).compactMap { $0 as? NSWindowController }, display2DViewerToolbar: display2DViewerToolbar)
    }
}

/// The current hanging protocol as an older header of the former plugin SDK
/// declared it, an instance variable of the application's delegate. The
/// protocol is the window layout manager's, set on the main thread as viewers
/// are opened and tiled: this observes it there and writes the delegate's
/// field at each change, for a plugin that reads the variable.
final class HangingProtocolOfOlderSDK: @unchecked Sendable {
    private let observation: NSKeyValueObservation?

    init() {
        observation = WindowLayoutManager.shared()?.observe(\.currentHangingProtocol, options: []) { _, _ in
            // The manager sets it on the main thread, which is where its observers are told.
            MainActor.assumeIsolated {
                let current = WindowLayoutManager.shared()?.currentHangingProtocol as NSDictionary?
                PreferencesSource.process.processGraph.appController?.currentHangingProtocol = current.map { NSMutableDictionary(dictionary: $0) }
            }
        }
    }
}

/// The flips of the view that last set its own, as an older header of the
/// former plugin SDK declared them, instance variables of the application's
/// delegate. A flip is each view's; a view tells here as it sets one, and the
/// delegate's field is written only when the value changes.
enum FlipsOfOlderSDK {
    @MainActor static func write(_ flipped: Bool, horizontal: Bool) {
        guard let delegate = PreferencesSource.process.processGraph.appController else { return }
        if horizontal {
            if delegate.xFlipped != flipped { delegate.xFlipped = flipped }
        } else if delegate.yFlipped != flipped {
            delegate.yFlipped = flipped
        }
    }
}
