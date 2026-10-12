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

import Darwin
import Foundation
import Synchronization

/// Whether the DICOM listeners are listening, and why not when they are not.
///
/// Ticking "Activate DICOM listener" and seeing nothing change looked the same
/// whether the listener had started or not: a port held by another
/// application, protected mode, a session that is not the active one or
/// settings the listener refuses each left it stopped with, at most, a line in
/// the log or a notice shown once. Every place that starts, stops or fails to
/// start a listener says so here, and the Listener preferences show it.
@objc(HorosListenerStatus)
public final class ListenerStatus: NSObject {
    /// Posted on the main thread after the state of a listener changed.
    @objc public static let didChangeNotification = Notification.Name("HorosListenerStatusDidChange")

    public enum State: Equatable, Sendable {
        case off
        case starting
        case listening(port: Int)
        case notListening(reason: String)
    }

    private struct Listeners {
        var plain = State.off
        var tls = State.off
    }

    private static let listeners = Mutex(Listeners())

    public static func state(tls: Bool) -> State {
        return listeners.withLock { tls ? $0.tls : $0.plain }
    }

    public static func set(_ state: State, tls: Bool) {
        let changed = listeners.withLock { (listeners: inout Listeners) -> Bool in
            let previous = tls ? listeners.tls : listeners.plain
            if tls { listeners.tls = state } else { listeners.plain = state }
            return previous != state
        }
        guard changed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - What the listeners and the application say

    @objc(setOffForTLS:)
    public static func setOff(tls: Bool) {
        set(.off, tls: tls)
    }

    @objc(setStartingForTLS:)
    public static func setStarting(tls: Bool) {
        set(.starting, tls: tls)
    }

    @objc(setListeningOnPort:TLS:)
    public static func setListening(port: Int, tls: Bool) {
        set(.listening(port: port), tls: tls)
    }

    @objc(setNotListening:TLS:)
    public static func setNotListening(reason: String, tls: Bool) {
        set(.notListening(reason: reason), tls: tls)
    }

    /// A listener that ends after having listened is off; one that never
    /// started keeps the reason it gave.
    @objc(setEndedForTLS:)
    public static func setEnded(tls: Bool) {
        listeners.withLock { (listeners: inout Listeners) in
            let state = tls ? listeners.tls : listeners.plain
            if case .notListening = state { return }
            if tls { listeners.tls = .off } else { listeners.plain = .off }
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }

    // MARK: - Reasons

    /// The port could not be opened: held by another application, or refused
    /// for the reason the system gives.
    @objc(bindFailureReasonForPort:errnoCode:)
    public static func bindFailureReason(port: Int, errno code: Int32) -> String {
        if code == EADDRINUSE {
            return String(format: NSLocalizedString("port %d is in use by another application", comment: "why the DICOM listener is not listening"), port)
        }
        let system = code != 0 ? String(cString: strerror(code)) : "unknown error"
        return String(format: NSLocalizedString("port %d could not be opened (%@)", comment: "why the DICOM listener is not listening"), port, system)
    }

    @objc public static var protectedModeReason: String {
        return NSLocalizedString("protected mode is on", comment: "why the DICOM listener is not listening")
    }

    @objc public static var inactiveSessionReason: String {
        return NSLocalizedString("this user session is not the active one", comment: "why the DICOM listener is not listening")
    }

    @objc public static var missingDictionaryReason: String {
        return NSLocalizedString("the DICOM dictionary could not be loaded", comment: "why the DICOM listener is not listening")
    }

    @objc public static var tlsSettingsReason: String {
        return NSLocalizedString("its TLS settings could not be applied", comment: "why the DICOM listener is not listening")
    }

    @objc public static var settingsReason: String {
        return NSLocalizedString("its AE title or settings are not valid", comment: "why the DICOM listener is not listening")
    }

    @objc public static var stillStoppingReason: String {
        return NSLocalizedString("the previous listener has not stopped", comment: "why the DICOM listener is not listening")
    }

    @objc(internalErrorReason:)
    public static func internalErrorReason(_ detail: String?) -> String {
        return String(format: NSLocalizedString("an internal error (%@)", comment: "why the DICOM listener is not listening"), detail ?? "")
    }

    // MARK: - What the preferences show

    public static func text(for state: State) -> String {
        switch state {
        case .off:
            return NSLocalizedString("The listener is off", comment: "DICOM listener status")
        case .starting:
            return NSLocalizedString("Starting the listener...", comment: "DICOM listener status")
        case .listening(let port):
            return String(format: NSLocalizedString("Listening on port %d", comment: "DICOM listener status"), port)
        case .notListening(let reason):
            return String(format: NSLocalizedString("Not listening: %@", comment: "DICOM listener status"), reason)
        }
    }

    public static func summary(plain: State, tls: State) -> String {
        if tls == .off { return text(for: plain) }
        return text(for: plain) + "\nTLS: " + text(for: tls)
    }

    /// The line of the Listener preferences: the listener's state and, when
    /// the TLS listener is not simply off, its state on a second line.
    @objc public static var summary: String {
        let (plain, tls) = listeners.withLock { ($0.plain, $0.tls) }
        return summary(plain: plain, tls: tls)
    }

    /// A listener that should be listening is not.
    @objc public static var hasFailure: Bool {
        return listeners.withLock { (listeners: inout Listeners) -> Bool in
            if case .notListening = listeners.plain { return true }
            if case .notListening = listeners.tls { return true }
            return false
        }
    }

    // MARK: - The IPv4 side of a port

    /// True when another socket already holds the IPv4 wildcard address of
    /// `port`. The listener's own socket is IPv6 and serves both families, and
    /// binding it then succeeds: both applications listen on the port and
    /// every IPv4 connection, which is what an archive sends, goes to the
    /// other one. Nothing is left bound.
    @objc(isIPv4PortTaken:)
    public static func isIPv4PortTaken(_ port: Int) -> Bool {
        guard port > 0, port <= 65535 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        // As the listener does: a port just left by a listener of this
        // application is free, one another socket listens on is not.
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = INADDR_ANY
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound != 0 && errno == EADDRINUSE
    }
}
