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
import IsiXHTTPServer
import IsiXPreferences

/// Which application the system gives each scheme of the links to, as the
/// workspace reports it, and the two changes the user can ask for: this
/// application takes a scheme, or gives it back to the one that had it.
///
/// Only the schemes the application declares are read or changed, only
/// through the workspace, and only when the user asked: by a button of the
/// notice at launch, by a box of the Listener preferences, or by having chosen
/// that it be done at every launch. After each change the system is asked
/// again, and the answer, not the request, is what is reported.
@MainActor
struct LinkSchemeRegistry {
    typealias Application = LinkSchemeHandlers.Application

    let preferences: any PreferenceStore

    /// The application that is running.
    static var running: Application {
        Application(identifier: Bundle.main.bundleIdentifier, path: HorosSchemeURL.runningBundlePath())
    }

    /// The application the system opens `scheme` with; nil when it has none.
    static func handler(of scheme: String) -> Application? {
        guard let url = URL(string: "\(scheme)://example"),
              let application = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return Application(identifier: Bundle(url: application)?.bundleIdentifier,
                           path: application.resolvingSymlinksInPath().path)
    }

    /// The declared schemes, each with the application that opens it now.
    static func handlers() -> [(scheme: String, handler: Application?)] {
        LinkSchemeHandlers.declared.map { (scheme: $0, handler: handler(of: $0)) }
    }

    static func isRunning(_ application: Application?) -> Bool {
        LinkSchemeHandlers.isRunningApplication(application, running: running)
    }

    /// An application as the user is told of it: the name the Finder shows
    /// and where it is, since two copies can have one name.
    static func describe(_ application: Application?) -> String {
        guard let application else {
            return NSLocalizedString("no application", comment: "Link schemes: in place of the name of the application that opens a scheme, when none does")
        }
        guard let path = application.path else { return application.identifier ?? "?" }
        return "\(FileManager.default.displayName(atPath: path)) (\(path))"
    }

    // MARK: - The application that had a scheme before

    /// The application `scheme` was taken from, when this one took it.
    func previousHandler(of scheme: String) -> Application? {
        guard let path = preferences[NetworkPreferences.linkSchemePreviousHandlers]?[scheme]?.stringValue,
              !path.isEmpty else { return nil }
        return Application(identifier: Bundle(path: path)?.bundleIdentifier, path: path)
    }

    private func remember(_ application: Application?, for scheme: String) {
        var stored = preferences[NetworkPreferences.linkSchemePreviousHandlers] ?? [:]
        if let path = application?.path {
            stored[scheme] = .string(path)
        } else {
            stored[scheme] = nil
        }
        preferences.set(stored.isEmpty ? nil : stored, for: NetworkPreferences.linkSchemePreviousHandlers)
    }

    // MARK: - Changes

    /// Makes this application the one that opens `scheme`. Answers nil once
    /// the system names it for the scheme, else what to tell the user.
    func take(_ scheme: String) async -> String? {
        let scheme = scheme.lowercased()
        guard LinkSchemeHandlers.isDeclared(scheme) else { return nil }
        let before = Self.handler(of: scheme)
        if Self.isRunning(before) { return nil }

        let error = await Self.setHandler(of: scheme, toApplicationAt: Bundle.main.bundleURL)
        let after = Self.handler(of: scheme)
        if Self.isRunning(after) {
            // Kept only now: what the box of the preferences gives the scheme back to.
            if before != nil { remember(before, for: scheme) }
            NSLog("link scheme %@: taken from %@", scheme as NSString, Self.logged(before) as NSString)
            return nil
        }
        NSLog("link scheme %@: not taken, still %@ (%@)", scheme as NSString, Self.logged(after) as NSString,
              (error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "no error") as NSString)
        let reason = error?.localizedDescription
            ?? String(format: NSLocalizedString("macOS still gives them to %@.", comment: "Link schemes: why a change did not happen; %@ is an application's name and path"),
                      Self.describe(after))
        return String(format: NSLocalizedString("IsiX DICOM Viewer could not be made the application that opens %@:// links. %@", comment: "Link schemes: %1$@ is a scheme, %2$@ the reason"),
                      scheme, reason)
    }

    /// What giving a scheme back came to.
    enum GiveBack: Equatable {
        case done
        /// No application is known to give it to: the scheme stays here.
        case kept
        case failed(String)
    }

    /// Gives `scheme` back to the application it was taken from, when that
    /// one is known and still there.
    func giveBack(_ scheme: String) async -> GiveBack {
        let scheme = scheme.lowercased()
        guard LinkSchemeHandlers.isDeclared(scheme) else { return .kept }
        let previous = previousHandler(of: scheme)
        let exists = previous?.path.map { FileManager.default.fileExists(atPath: $0) } ?? false
        guard case .giveBack(let application) = LinkSchemeHandlers.release(previous: previous, previousExists: exists, running: Self.running),
              let path = application.path else { return .kept }

        let error = await Self.setHandler(of: scheme, toApplicationAt: URL(fileURLWithPath: path))
        let after = Self.handler(of: scheme)
        if !Self.isRunning(after) {
            remember(nil, for: scheme)
            NSLog("link scheme %@: given back, now %@", scheme as NSString, Self.logged(after) as NSString)
            return .done
        }
        NSLog("link scheme %@: not given back to %@ (%@)", scheme as NSString, Self.logged(application) as NSString,
              (error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" } ?? "no error") as NSString)
        let reason = error?.localizedDescription
            ?? String(format: NSLocalizedString("macOS still gives them to %@.", comment: "Link schemes: why a change did not happen; %@ is an application's name and path"),
                      Self.describe(after))
        return .failed(String(format: NSLocalizedString("%@:// links could not be given back to %@. %@", comment: "Link schemes: %1$@ is a scheme, %2$@ an application's name and path, %3$@ the reason"),
                              scheme, Self.describe(application), reason))
    }

    /// Asks the workspace to open `scheme` with the application at `url`, and
    /// waits for its answer: the error it gives, if any. The system may ask
    /// the user to agree first; a refusal is an error like another.
    private static func setHandler(of scheme: String, toApplicationAt url: URL) async -> (any Error)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(any Error)?, Never>) in
            NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: scheme) { error in
                continuation.resume(returning: error)
            }
        }
    }

    /// An application in a line of the log: its identifier and its path.
    private static func logged(_ application: Application?) -> String {
        guard let application else { return "no application" }
        return "\(application.identifier ?? "?") at \(application.path ?? "?")"
    }
}
