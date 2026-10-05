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

import CoreGraphics
import Foundation

/// A start that leaves out everything that can make the application close by
/// itself while it opens, so that the user can reach the database and delete
/// whatever study is at fault.
///
/// It is asked for by holding Shift and Option while the application opens, or
/// with `-ProtectedMode YES` on the command line. The keys are read in `main`,
/// before any preference, plugin or nib is loaded: by the time the browser
/// window exists the plugins have already been loaded.
///
/// In this mode no plugin is loaded, no image is shown, and the DICOM
/// listeners, auto-routing, automatic cleaning, the Web Portal, the XML-RPC
/// server, Bonjour publishing, automatic update checks and window restoration
/// stay off. Each of those start points asks `isActive`. Nothing here writes a
/// saved preference: the next normal start behaves as it always did.
@objc(HorosProtectedMode)
public final class ProtectedMode: NSObject {

    /// The command-line switch, `-ProtectedMode YES`.
    static let argumentKey = "ProtectedMode"
    /// Read by AppKit to skip restoring the previous session's windows.
    static let ignoreSavedStateKey = "ApplePersistenceIgnoreState"

    /// True when Shift and Option are both held, or the argument says yes.
    /// Only the argument domain counts: a saved preference never turns the
    /// mode on by itself.
    static func isRequested(flags: CGEventFlags, argument: Any?) -> Bool {
        if flags.contains(.maskShift) && flags.contains(.maskAlternate) {
            return true
        }
        switch argument {
        case let text as String: return (text as NSString).boolValue
        case let number as NSNumber: return number.boolValue
        default: return false
        }
    }

    /// Called from `main`, ahead of `NSApplicationMain`.
    @objc public static func activateIfRequested() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard isRequested(flags: CGEventSource.flagsState(.combinedSessionState),
                          argument: arguments[argumentKey]) else { return }
        activate()
    }

    /// Turns the mode on for this process.
    @objc public static func activate() {
        DCMPix.setRunOsiriXInProtectedMode(true)
        // Merged into the argument domain, which lives only as long as the
        // process: replacing it would drop the arguments the application was
        // started with, and writing the key to the application's domain would
        // carry it into the next start.
        let defaults = UserDefaults.standard
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[ignoreSavedStateKey] = "YES"
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        NSLog("WARNING ---- Protected Mode Activated: no plugins, no images, no DICOM listener, auto-routing, automatic cleaning, Web Portal, XML-RPC server, Bonjour publishing, automatic update checks or window restoration")
    }

    @objc public static var isActive: Bool {
        DCMPix.isRunOsiriXInProtectedModeActivated()
    }

    /// Logs a service left off, for whoever reads the log after a support call.
    /// The name goes into the format itself: the unified log shows arguments as
    /// <private>, and these names are fixed strings of this application.
    @objc(skip:) public static func skip(_ service: String) {
        NSLog(("Protected Mode: " + service + " not started").replacingOccurrences(of: "%", with: "%%"))
    }

    /// The sentence of the alert shown when the browser opens in this mode.
    @objc public static var alertMessage: String {
        NSLocalizedString("IsiX DICOM Viewer is running in Protected Mode: no images are displayed, so you can delete a study that makes it close by itself.\n\nOff for this session: plugins, the DICOM listener (with and without TLS), auto-routing, automatic cleaning, the Web Portal, the XML-RPC server, Bonjour sharing, automatic update checks and window restoration. Your saved preferences are not changed.\n\nTo leave Protected Mode, quit IsiX DICOM Viewer and open it again without holding Shift and Option.", comment: "Protected Mode alert")
    }
}
