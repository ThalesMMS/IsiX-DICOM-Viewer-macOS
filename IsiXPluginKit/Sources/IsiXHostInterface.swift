//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The host's side of the kit. These declarations are SPI: the application
// imports them with `@_spi(IsiXHost) import IsiXPluginKit`, and they are left
// out of the public module interface plugins compile against. A plugin sees
// only the final classes and value types; the host implements these backends
// with its own viewer, image and ROI classes, which never cross to a plugin.

import AppKit
import ObjectiveC

/// One viewer, as the host implements it.
@_spi(IsiXHost)
@MainActor
public protocol IsiXViewerBackend: AnyObject {
    var viewerID: IsiXViewerID { get }
    /// False from the moment the viewer starts closing; the backend must not
    /// keep the viewer alive.
    var isOpen: Bool { get }
    func seriesSummary() throws -> IsiXSeriesSummary
    func currentPosition() throws -> IsiXSlicePosition
    func setCurrentSlice(_ slice: Int) throws
    func image(slice: Int?, phase: Int?) throws -> IsiXImage
    func windowLevel() throws -> IsiXWindowLevel
    func setWindowLevel(_ windowLevel: IsiXWindowLevel) throws
    func commit(_ pixels: IsiXPixelData, replacing version: IsiXImageVersion) throws
    func rois(slice: Int?, phase: Int?) throws -> [IsiXROI]
    func addROI(_ draft: IsiXROIDraft) throws -> IsiXROI
    func removeROI(_ id: IsiXROIID) throws
    func statistics(of id: IsiXROIID) throws -> IsiXROIStatistics
    func setNeedsDisplay()
    func geometry(slice: Int?, phase: Int?) throws -> IsiXImageGeometry
    func attributes(slice: Int?, phase: Int?) throws -> IsiXImageAttributes
    func statistics(of id: IsiXROIID, slice: Int, phase: Int) throws -> IsiXROIStatistics
    /// Opens a new viewer with the series and returns its backend.
    func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> any IsiXViewerBackend
    /// Changes the ROI in place and returns it as it is afterwards.
    func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI
    /// Shows another phase of the series, at the same slice.
    func setCurrentPhase(_ phase: Int) throws
}

/// What a backend written before these requirements existed answers.
@_spi(IsiXHost)
public extension IsiXViewerBackend {
    func geometry(slice: Int?, phase: Int?) throws -> IsiXImageGeometry {
        try image(slice: slice, phase: phase).geometry
    }

    func attributes(slice: Int?, phase: Int?) throws -> IsiXImageAttributes {
        try image(slice: slice, phase: phase).attributes
    }

    func statistics(of id: IsiXROIID, slice: Int, phase: Int) throws -> IsiXROIStatistics {
        throw IsiXPluginError.hostFailure("This application cannot measure a ROI on another image.")
    }

    func openDerivedSeries(_ series: IsiXDerivedSeries) throws -> any IsiXViewerBackend {
        throw IsiXPluginError.hostFailure("This application cannot open a derived series.")
    }

    func updateROI(_ id: IsiXROIID, _ update: IsiXROIUpdate) throws -> IsiXROI {
        throw IsiXPluginError.hostFailure("This application cannot change a ROI of a plugin.")
    }

    func setCurrentPhase(_ phase: Int) throws {
        throw IsiXPluginError.hostFailure("This application cannot show another phase for a plugin.")
    }
}

/// The application, as the host implements it.
@_spi(IsiXHost)
@MainActor
public protocol IsiXHostBackend: AnyObject {
    func frontmostViewer() -> (any IsiXViewerBackend)?
    func openViewers() -> [any IsiXViewerBackend]
    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)?
    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow?
    func selectedStudies() async throws -> [IsiXStudy]
    func study(withInstanceUID uid: String) async throws -> IsiXStudy?
    func series(inStudy studyInstanceUID: String) async throws -> [IsiXSeries]
    func importFiles(at urls: [URL]) async throws -> IsiXImportResult
    /// A plugin added or removed a command: the menus need rebuilding.
    func commandsDidChange()
    func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) async throws -> [URL]
}

@_spi(IsiXHost)
public extension IsiXHostBackend {
    func writeDerivedSeries(_ request: IsiXDerivedSeriesRequest) async throws -> [URL] {
        throw IsiXPluginError.hostFailure("This application cannot write DICOM files for plugins.")
    }
}

/// Why a bundle's entry class could not be used. Found after the bundle's
/// executable was loaded and before any of the plugin's code runs.
@_spi(IsiXHost)
public enum IsiXEntryError: Error, Sendable, Equatable {
    /// No class of that name is known to the runtime.
    case classNotFound(String)
    /// The class exists, but in another image than the bundle's executable.
    case classOutsideBundle(String, image: String)
    /// The class does not adopt `IsiXPlugin`.
    case notAPlugin(String)

    public var message: String {
        switch self {
        case .classNotFound(let name):
            return "The entry class \(name) was not found in the plugin. Name it ModuleName.ClassName in NSPrincipalClass."
        case .classOutsideBundle(let name, let image):
            return "The entry class \(name) belongs to \(image), not to the plugin."
        case .notAPlugin(let name):
            return "The entry class \(name) does not adopt IsiXPlugin."
        }
    }
}

/// Why the runtime refused to run a command before calling its handler.
@_spi(IsiXHost)
public enum IsiXCommandRefusal: Error, Sendable, Equatable, LocalizedError {
    /// The command, by title, needs an open 2D viewer and none is open.
    case viewerRequired(String)

    public var errorDescription: String? {
        switch self {
        case .viewerRequired(let title):
            return "\"\(title)\" needs an open 2D viewer. Open a series and choose the command again."
        }
    }
}

/// The sentence the host shows the user for an error a plugin's command or
/// activation threw: the error's `LocalizedError.errorDescription`, the
/// localized description of a Cocoa or system error, or else its description.
@_spi(IsiXHost)
public func IsiXUserMessage(for error: any Error) -> String {
    if let localized = error as? any LocalizedError, let text = localized.errorDescription, !text.isEmpty {
        return text
    }
    let bridged = error as NSError
    let systemDomains = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSURLErrorDomain, NSMachErrorDomain]
    if bridged.userInfo[NSLocalizedDescriptionKey] != nil || systemDomains.contains(bridged.domain) {
        return bridged.localizedDescription
    }
    return String(describing: error)
}

/// Resolves, creates, activates and deactivates one plugin for the host,
/// and routes events and commands to it.
@_spi(IsiXHost)
@MainActor
public final class IsiXPluginRuntime {
    public enum State: Equatable, Sendable {
        case resolved, active, failed(String), deactivated
    }

    /// The class `className` names, once the bundle's executable at
    /// `executableURL` is loaded: a Swift class by its module-qualified name
    /// or any class by its Objective-C name. `Bundle.classNamed(_:)` does not
    /// find Swift classes, so the runtime is asked by name and the class's
    /// image must be the bundle's executable: a plugin cannot name a class of
    /// the application or of another plugin.
    public nonisolated static func resolveEntry(named className: String, executableURL: URL) throws(IsiXEntryError) -> any IsiXPlugin.Type {
        guard let found: AnyClass = NSClassFromString(className) else { throw .classNotFound(className) }
        let image = class_getImageName(found).map { String(cString: $0) } ?? ""
        let expected = executableURL.resolvingSymlinksInPath().standardizedFileURL.path
        let actual = URL(fileURLWithPath: image).resolvingSymlinksInPath().standardizedFileURL.path
        guard !image.isEmpty, actual == expected else { throw .classOutsideBundle(className, image: image) }
        guard let type = found as? any IsiXPlugin.Type else { throw .notAPlugin(className) }
        return type
    }

    public let info: IsiXPluginInfo
    public private(set) var state: State = .resolved
    private let entry: any IsiXPlugin.Type
    let context: IsiXPluginContext
    private var plugin: (any IsiXPlugin)?

    public init(info: IsiXPluginInfo, bundle: Bundle, entry: any IsiXPlugin.Type, host: any IsiXHostBackend) {
        self.info = info
        self.entry = entry
        self.context = IsiXPluginContext(info: info, bundle: bundle, host: host)
    }

    /// Creates the plugin and activates it. When activation throws, whatever
    /// the plugin registered is removed and the plugin is dropped.
    public func activate() throws {
        guard state == .resolved else { return }
        let instance = entry.init()
        do {
            try instance.activate(with: context)
            plugin = instance
            state = .active
        } catch {
            context.close()
            state = .failed(IsiXUserMessage(for: error))
            throw error
        }
    }

    /// Drops a plugin whose activation neither returned nor threw: the host
    /// caught an exception that escaped it. Whatever the plugin registered is
    /// removed, its tasks are cancelled, and it is not called again, not even
    /// to deactivate.
    public func abandon(reason: String) {
        guard state == .resolved || state == .active else { return }
        context.close()
        plugin = nil
        state = .failed(reason)
    }

    /// Cancels the plugin's tasks, removes its observations and commands, then
    /// lets it clean up. Called once, before the application quits.
    public func deactivate() {
        guard state == .active, let plugin else { return }
        context.close()
        plugin.deactivate()
        self.plugin = nil
        state = .deactivated
    }

    /// The plugin object while it is active, for diagnostics.
    public var instance: (any IsiXPlugin)? { plugin }

    /// The commands the plugin registered, in order.
    public var commands: [IsiXCommand] { context.commands }

    public var observationCount: Int { context.observations.count }

    public var runningTaskCount: Int { context.runningTaskCount }

    /// Whether the command can run now; the menu item is disabled otherwise.
    public func canRun(commandID: String, frontmostViewerOpen: Bool) -> Bool {
        guard state == .active, let command = commands.first(where: { $0.id == commandID }) else { return false }
        switch command.requirement {
        case .none: return true
        case .viewer: return frontmostViewerOpen
        }
    }

    /// Runs a command's handler and passes on what it throws. A command that
    /// needs a viewer is refused without one, as the menu disables it: the
    /// handler is not called.
    public func run(commandID: String) throws {
        guard state == .active, let command = commands.first(where: { $0.id == commandID }),
              let handler = context.handler(for: commandID) else {
            throw IsiXPluginError.pluginInactive
        }
        guard canRun(commandID: commandID, frontmostViewerOpen: context.frontmostViewerIsOpen) else {
            throw IsiXCommandRefusal.viewerRequired(command.title)
        }
        try handler(context.invocation(for: command))
    }

    public func deliver(_ event: IsiXEvent) {
        guard state == .active else { return }
        context.deliver(event)
    }

    /// The kinds of input the plugin's handlers take: none while it is not
    /// active or may not read viewers.
    public var inputKinds: IsiXInputKinds {
        guard state == .active else { return [] }
        return context.inputKinds
    }

    /// Gives a mouse or key event of a viewer to the plugin's input handlers;
    /// true when one of them took it, and the viewer does nothing else with it.
    public func handleInput(_ input: IsiXViewerInput) -> Bool {
        guard state == .active else { return false }
        return context.handleInput(input)
    }

    /// Whether the plugin draws over this viewer's image.
    public func hasOverlays(on viewer: IsiXViewerID) -> Bool {
        state == .active && context.hasOverlays(on: viewer)
    }

    /// Calls the plugin's overlays of the viewer, each in its own graphics state.
    public func drawOverlays(_ overlay: IsiXOverlayContext) {
        guard state == .active else { return }
        context.drawOverlays(overlay)
    }
}
