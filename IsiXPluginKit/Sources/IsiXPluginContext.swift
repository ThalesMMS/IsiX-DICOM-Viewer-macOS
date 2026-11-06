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

/// What the host gives a plugin: its identity and bundle, commands, viewers,
/// events, the database and tasks. One per plugin, valid from activation to
/// deactivation; afterwards its methods throw `pluginInactive` or do nothing.
@MainActor
public final class IsiXPluginContext {
    public let info: IsiXPluginInfo
    /// The plugin's own bundle, for its resources.
    public let bundle: Bundle

    let host: any IsiXHostBackend
    let observations = ObservationRegistry()
    /// The XML-RPC methods the plugin answers; see IsiXXMLRPC.swift.
    let xmlRPCMethods = IsiXXMLRPCRegistry()
    private(set) var commands: [IsiXCommand] = []
    private var handlers: [String: @MainActor (IsiXCommandInvocation) throws -> Void] = [:]
    private var tasks: [ObjectIdentifier: IsiXTask] = [:]
    private(set) var isActive = true

    init(info: IsiXPluginInfo, bundle: Bundle, host: any IsiXHostBackend) {
        self.info = info
        self.bundle = bundle
        self.host = host
    }

    func requireActive() throws {
        guard isActive else { throw IsiXPluginError.pluginInactive }
    }

    // MARK: commands

    /// Adds a menu command. The host shows it in the menu its placement
    /// names and calls `handler` on the main actor when the user picks it.
    public func register(_ command: IsiXCommand, handler: @escaping @MainActor (IsiXCommandInvocation) throws -> Void) throws {
        try requireActive()
        guard !command.id.isEmpty, !command.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw IsiXPluginError.invalidCommand(command.id)
        }
        guard handlers[command.id] == nil else { throw IsiXPluginError.commandAlreadyRegistered(command.id) }
        commands.append(command)
        handlers[command.id] = handler
        host.commandsDidChange()
    }

    public func unregisterCommand(id: String) {
        guard handlers.removeValue(forKey: id) != nil else { return }
        commands.removeAll { $0.id == id }
        host.commandsDidChange()
    }

    func handler(for id: String) -> (@MainActor (IsiXCommandInvocation) throws -> Void)? {
        handlers[id]
    }

    // MARK: viewers

    /// The frontmost 2D viewer, if one is open.
    public func frontmostViewer() throws -> IsiXViewer? {
        try requireActive()
        try requireCapability(.viewerRead)
        return host.frontmostViewer().map { IsiXViewer(backend: $0, capabilities: info.capabilities, registry: observations) }
    }

    /// The open 2D viewers, frontmost first.
    public func openViewers() throws -> [IsiXViewer] {
        try requireActive()
        try requireCapability(.viewerRead)
        return host.openViewers().map { IsiXViewer(backend: $0, capabilities: info.capabilities, registry: observations) }
    }

    /// The viewer with this identifier, if it is still open.
    public func viewer(withID id: IsiXViewerID) throws -> IsiXViewer? {
        try requireActive()
        try requireCapability(.viewerRead)
        return host.viewer(withID: id).map { IsiXViewer(backend: $0, capabilities: info.capabilities, registry: observations) }
    }

    // MARK: events

    /// Calls `handler` on the main actor for each event of `kinds` the plugin
    /// may see, until the returned observation is invalidated or released, or
    /// the plugin is deactivated.
    public func observe(_ kinds: IsiXEventKinds = .all, _ handler: @escaping @MainActor (IsiXEvent) -> Void) throws -> IsiXObservation {
        try requireActive()
        guard let key = observations.add(kinds, handler) else { throw IsiXPluginError.pluginInactive }
        return IsiXObservation(registry: observations, key: key)
    }

    // MARK: database

    /// The local database; its methods need `database.read`, `database.import`
    /// or `database.write`.
    public func database() throws -> IsiXDatabase {
        try requireActive()
        guard info.capabilities.contains(.databaseRead) || info.capabilities.contains(.databaseImport)
            || info.capabilities.contains(.databaseWrite) else {
            throw IsiXPluginError.capabilityNotDeclared(.databaseRead)
        }
        return IsiXDatabase(host: host, capabilities: info.capabilities)
    }

    // MARK: tasks

    /// Runs `operation` outside the main actor. It is cancelled when the
    /// plugin is deactivated; it should check `Task.isCancelled` or
    /// `progress.isCancelled` and return.
    @discardableResult
    public func startTask(named name: String, _ operation: @escaping @Sendable (IsiXTaskProgress) async throws -> Void) throws -> IsiXTask {
        try requireActive()
        let task = IsiXTask(name: name, progress: IsiXTaskProgress())
        tasks[ObjectIdentifier(task)] = task
        task.start(operation) { [weak self] finished in
            self?.tasks[ObjectIdentifier(finished)] = nil
        }
        return task
    }

    var runningTaskCount: Int { tasks.count }

    // MARK: lifecycle

    func requireCapability(_ capability: IsiXCapability) throws {
        guard info.capabilities.contains(capability) else { throw IsiXPluginError.capabilityNotDeclared(capability) }
    }

    /// Cancels the tasks, removes observations and commands, and refuses new ones.
    func close() {
        guard isActive else { return }
        isActive = false
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        observations.close()
        xmlRPCMethods.close()
        let hadCommands = !commands.isEmpty
        commands.removeAll()
        handlers.removeAll()
        if hadCommands { host.commandsDidChange() }
    }

    func deliver(_ event: IsiXEvent) {
        guard isActive else { return }
        switch event {
        case .viewerOpened, .viewerWillClose, .sliceChanged:
            guard info.capabilities.contains(.viewerRead) else { return }
        case .roiChanged:
            guard info.capabilities.contains(.viewerRead), info.capabilities.contains(.roi) else { return }
        case .imagesAdded:
            guard info.capabilities.contains(.databaseRead) else { return }
        }
        observations.deliver(event)
    }

    /// Whether the host has a frontmost 2D viewer, whatever the plugin may read of it.
    var frontmostViewerIsOpen: Bool { host.frontmostViewer() != nil }

    func invocation(for command: IsiXCommand) -> IsiXCommandInvocation {
        let viewer = info.capabilities.contains(.viewerRead)
            ? host.frontmostViewer().map { IsiXViewer(backend: $0, capabilities: info.capabilities, registry: observations) } : nil
        return IsiXCommandInvocation(command: command, viewer: viewer, parentWindow: host.parentWindow(forViewer: viewer?.id))
    }
}
