//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// Plugins that misbehave on purpose, compiled into one probe bundle by
// tests/test-isix-plugin-kit.py; the host harness picks one by class name.

import Foundation
import IsiXPluginKit
import Synchronization
import CoreGraphics

struct ProbeFailure: Error, CustomStringConvertible {
    var description: String { "the probe refused to activate" }
}

/// Registers a command and an observation, then refuses to activate.
public final class ThrowingPlugin: IsiXPlugin {
    private var observation: IsiXObservation?
    public init() {}
    public func activate(with context: IsiXPluginContext) throws {
        try context.register(IsiXCommand(id: "never", title: "Never shown")) { _ in }
        observation = try context.observe { _ in }
        throw ProbeFailure()
    }
}

/// Not a plugin: the entry must adopt IsiXPlugin.
public final class NotAPlugin {
    public init() {}
}

/// Counts events; drops its observation token after the first one, keeps a
/// second token until it is invalidated, and starts a task that waits to be
/// cancelled.
public final class ObserverPlugin: IsiXPlugin, CustomStringConvertible {
    private var dropped: IsiXObservation?
    private var kept: IsiXObservation?
    private var context: IsiXPluginContext?
    private var droppedCount = 0
    private var keptCount = 0
    private var cancelled = false
    private var deactivated = false
    private var offMain = false
    private var errors: [String] = []
    /// The line `description` shows, refreshed on the main actor after each change.
    private let summary = Mutex("")

    public init() {}

    public nonisolated var description: String { summary.withLock { $0 } }

    private func refresh() {
        let line = "dropped \(droppedCount) kept \(keptCount) cancelled \(cancelled) offMain \(offMain) deactivated \(deactivated) errors \(errors.joined(separator: ","))"
        summary.withLock { $0 = line }
    }

    public func activate(with context: IsiXPluginContext) throws {
        self.context = context
        dropped = try context.observe([.sliceChanged]) { [weak self] _ in
            self?.droppedCount += 1
            self?.dropped = nil
            self?.refresh()
        }
        kept = try context.observe([.sliceChanged, .roiChanged]) { [weak self] _ in
            self?.keptCount += 1
            self?.refresh()
        }
        try context.startTask(named: "Wait for cancellation") { progress in
            let ranOffMain = pthread_main_np() == 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            let sawFlag = progress.isCancelled
            await MainActor.run { [weak self] in
                self?.cancelled = sawFlag
                self?.offMain = ranOffMain
                self?.refresh()
            }
        }
        // Undeclared capabilities are refused, not silently granted.
        do { _ = try context.database() } catch { errors.append("\(error)") }
        try context.register(IsiXCommand(id: "invalidate", title: "Invalidate")) { [weak self] _ in
            self?.kept?.invalidate()
        }
        do {
            try context.register(IsiXCommand(id: "invalidate", title: "Again")) { _ in }
        } catch {
            errors.append("\(error)")
        }
        refresh()
    }

    public func deactivate() {
        deactivated = true
        refresh()
    }
}

/// Takes clicks in the left half of the image and the key x, draws over the
/// viewer of a command, and gives its input handler and overlay up when asked.
public final class InteractionPlugin: IsiXPlugin, CustomStringConvertible {
    private var input: IsiXObservation?
    private var overlay: IsiXObservation?
    private var seen: [String] = []
    private var drawn: [String] = []
    private var errors: [String] = []
    private let summary = Mutex("")

    public init() {}

    public nonisolated var description: String { summary.withLock { $0 } }

    private func refresh() {
        let line = "seen \(seen.joined(separator: ",")) drawn \(drawn.joined(separator: ",")) errors \(errors.joined(separator: ","))"
        summary.withLock { $0 = line }
    }

    public func activate(with context: IsiXPluginContext) throws {
        input = try context.interceptInput([.mouseDown, .keyDown]) { [weak self] event in
            guard let self else { return false }
            self.seen.append("\(event.kind) \(Int(event.location.x)),\(Int(event.location.y)) slice \(event.position.slice)\(event.characters ?? "")")
            self.refresh()
            return event.kind == .keyDown ? event.characters == "x" : event.location.x < 4
        }
        try context.register(IsiXCommand(id: "overlay", title: "Overlay", requirement: .viewer)) { [weak self] invocation in
            guard let self, let viewer = invocation.viewer else { return }
            self.overlay = try viewer.addOverlay { [weak self] overlay in
                // Pixel (1, 2): its centre is at (1, 2), its edges half a pixel away.
                overlay.cgContext.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
                overlay.cgContext.fill(CGRect(x: 0.5, y: 1.5, width: 1, height: 1))
                self?.drawn.append("slice \(overlay.position.slice) point \(overlay.pointSize)")
                self?.refresh()
            }
            do { try viewer.setCurrentPhase(0) } catch { self.errors.append("phase \(error)") }
            self.refresh()
        }
        try context.register(IsiXCommand(id: "drop", title: "Drop")) { [weak self] _ in
            self?.input?.invalidate()
            self?.overlay = nil
        }
        refresh()
    }

    public func deactivate() {}
}
