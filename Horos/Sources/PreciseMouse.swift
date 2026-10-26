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

import AppKit

/// Sensitivity applies to movement, never to hit testing or the image's coordinates.
@objc(HorosPreciseMouse)
public final class PreciseMouse: NSObject {
    public static let enabledKey = "PreciseMouseForMeasuringAndZoom"
    public static let factorKey = "PreciseMouseFactor"

    @objc public static var effectiveFactor: Double {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: enabledKey) else { return 1 }
        let factor = defaults.double(forKey: factorKey)
        return [0.25, 0.5, 0.75].contains(factor) ? factor : 0.5
    }

    @objc(appliedDelta:)
    public static func appliedDelta(_ delta: Double) -> Double {
        let factor = effectiveFactor
        return factor == 1 ? delta : delta * factor
    }

    /// Use the original mouse-down anchor on every event to avoid compounding.
    public static func point(_ point: NSPoint, from anchor: NSPoint) -> NSPoint {
        let factor = effectiveFactor
        guard factor != 1 else { return point }
        return NSPoint(x: anchor.x + (point.x - anchor.x) * factor,
                       y: anchor.y + (point.y - anchor.y) * factor)
    }
}

/// What a precise drag does to the system cursor; a test replaces it. Points are
/// global display coordinates, from the top left of the main display.
protocol PreciseDragCursor {
    func detach(at point: CGPoint)
    func move(to point: CGPoint)
    func attach()
}

struct SystemPreciseDragCursor: PreciseDragCursor {
    func detach(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(0)
    }

    func move(to point: CGPoint) { CGWarpMouseCursorPosition(point) }

    func attach() { CGAssociateMouseAndMouseCursorPosition(1) }
}

/// A precise drag keeps the system cursor on the point it moves. Scaling the
/// cursor's own position left the point further behind the cursor the longer the
/// drag. Here the cursor is detached from the mouse for the drag: the point
/// advances by the mouse's movement times the factor, and the cursor is put back
/// on it after each event. Any button's release, the application going to the
/// background or the window closing attaches the mouse again.
@MainActor
enum PreciseDrag {
    static var cursor: PreciseDragCursor = SystemPreciseDragCursor()
    private static var active = false
    private static weak var window: NSWindow?
    /// The dragged point, in the window's coordinates.
    private static var point = NSPoint.zero
    private static weak var lastEvent: NSEvent?
    private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []

    /// Where `event` puts the dragged point, in `window`'s coordinates. `anchor`
    /// is the mouse-down point there; `precise` says whether this drag scales.
    static func location(of event: NSEvent, in window: NSWindow?, anchor: NSPoint, precise: Bool) -> NSPoint {
        // The drag handlers ask more than once for the same event.
        if active, event === lastEvent, window === self.window { return point }
        lastEvent = event
        let dragged = [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged].contains(event.type)
        return step(in: window, location: event.locationInWindow,
                    delta: dragged ? CGVector(dx: event.deltaX, dy: -event.deltaY) : .zero,
                    dragged: dragged, anchor: anchor, precise: precise)
    }

    /// The dragged point while a precise drag runs in `window`, the event's otherwise.
    static func trackedLocation(of event: NSEvent?, in window: NSWindow?) -> NSPoint {
        if active, let window, window === self.window { return point }
        return event?.locationInWindow ?? .zero
    }

    /// `delta` is the mouse's movement in window orientation, y upwards.
    static func step(in window: NSWindow?, location: NSPoint, delta: CGVector, dragged: Bool,
                     anchor: NSPoint, precise: Bool) -> NSPoint {
        guard precise, PreciseMouse.effectiveFactor != 1, let window else { end(); return location }
        let factor = PreciseMouse.effectiveFactor
        if active && window === self.window {
            guard dragged else { return point }
            point.x += delta.dx * factor
            point.y += delta.dy * factor
            cursor.move(to: displayPoint(point, in: window))
            return point
        }
        end()
        // The drag that mouse-down sends itself and the replay of a two-click
        // length carry no movement: they place the point where the cursor is.
        guard dragged, delta.dx != 0 || delta.dy != 0 else { return location }
        // The cursor has already gone this far on its own: the point starts at
        // the scaled share of it, and the cursor goes there.
        point = PreciseMouse.point(location, from: anchor)
        self.window = window
        active = true
        cursor.detach(at: displayPoint(point, in: window))
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]) { event in
            MainActor.assumeIsolated { end() }
            return event
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            },
        ]
        return point
    }

    static func end() {
        guard active else { return }
        active = false
        window = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        cursor.attach()
    }

    static func displayPoint(_ point: NSPoint, in window: NSWindow) -> CGPoint {
        let screen = window.convertPoint(toScreen: point)
        return CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y)
    }
}
