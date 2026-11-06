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

/// A menu command of a plugin.
public struct IsiXCommand: Hashable, Sendable {
    /// Which of the application's plugin menus shows the command.
    public enum Placement: Hashable, Sendable {
        /// The viewer's image filters.
        case imageFilters
        /// The viewer's ROI tools.
        case roiTools
        /// The database window's plugins.
        case database
        case other
    }

    /// When the command can run; the menu item is disabled otherwise.
    public enum Requirement: Hashable, Sendable {
        case none
        /// An open 2D viewer: the invocation carries the frontmost one.
        case viewer
    }

    /// Stable within the plugin: the host uses it, never the title, to tell commands apart.
    public var id: String
    /// The menu item's title.
    public var title: String
    public var placement: Placement
    public var requirement: Requirement

    public init(id: String, title: String, placement: Placement = .other, requirement: Requirement = .none) {
        self.id = id
        self.title = title
        self.placement = placement
        self.requirement = requirement
    }
}

/// One run of a command.
@MainActor
public final class IsiXCommandInvocation {
    public let command: IsiXCommand
    /// The frontmost 2D viewer when the command ran, if there is one and the
    /// plugin declared `viewer.read`.
    public let viewer: IsiXViewer?
    /// A window to attach sheets to: the viewer's, or the database window's.
    public let parentWindow: NSWindow?

    init(command: IsiXCommand, viewer: IsiXViewer?, parentWindow: NSWindow?) {
        self.command = command
        self.viewer = viewer
        self.parentWindow = parentWindow
    }
}

/// Long work of a plugin, cancelled when the plugin is deactivated.
@MainActor
public final class IsiXTask {
    public let name: String
    public let progress: IsiXTaskProgress
    private var task: Task<Void, any Error>?
    public private(set) var isFinished = false
    public private(set) var error: (any Error)?

    init(name: String, progress: IsiXTaskProgress) {
        self.name = name
        self.progress = progress
    }

    func start(_ operation: @escaping @Sendable (IsiXTaskProgress) async throws -> Void, finished: @escaping @MainActor (IsiXTask) -> Void) {
        let progress = self.progress
        // Detached: the operation runs off the main actor whatever isolation
        // the plugin's compiler gives a nonisolated async closure.
        task = Task.detached { [weak self] in
            var failure: (any Error)?
            do {
                try await operation(progress)
            } catch {
                failure = error
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isFinished = true
                self.error = failure
                finished(self)
            }
        }
    }

    /// Asks the operation to stop: `Task.isCancelled` and `progress.isCancelled` become true.
    public func cancel() {
        progress.markCancelled()
        task?.cancel()
    }

    /// Waits for the operation to end, and rethrows what it threw.
    public func value() async throws {
        try await task?.value
    }
}

/// Reports the progress of an `IsiXTask` from any thread.
public final class IsiXTaskProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var fraction = 0.0
    private var text: String?
    private var cancelled = false

    init() {}

    public var fractionCompleted: Double {
        lock.lock(); defer { lock.unlock() }
        return fraction
    }

    public var message: String? {
        lock.lock(); defer { lock.unlock() }
        return text
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// `fraction` between 0 and 1.
    public func report(_ fraction: Double, message: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        self.fraction = min(max(fraction, 0), 1)
        if let message { text = message }
    }

    func markCancelled() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}
