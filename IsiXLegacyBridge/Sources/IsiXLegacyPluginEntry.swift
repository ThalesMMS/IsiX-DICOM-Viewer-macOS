//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The entry point of a ported plugin. The bundle's NSPrincipalClass names this
// class, qualified by the plugin's module; it reads the legacy plugin's class,
// type and menu titles from the Info.plist, creates the legacy filter, and
// turns each menu title into a command of the plugin API. Everything the
// legacy source does goes through the kit's classes to IsiXPluginKit only.
//
// The kit's Swift is compiled into the plugin's own module, so its classes get
// names of that module in the Objective-C runtime and two ported plugins never
// share one.

import AppKit
import IsiXPluginKit

/// What the kit's PluginFilter answers, for the entry to drive it.
@objc protocol IsiXLegacyFilterHost: NSObjectProtocol {
    /// Calls -initPlugin and -setMenus once, after the plugin was loaded.
    @objc(isixLegacyStart) func isixLegacyStart()
    /// Prepares the filter for the viewer and calls -filterImage:.
    @objc(isixLegacyRunMenu:viewer:) func isixLegacyRun(menu: String, viewer: IsiXLegacyViewerSession?) -> Int
    /// Calls -willUnload.
    @objc(isixLegacyStop) func isixLegacyStop()
}

/// Info.plist keys of a ported plugin: the former keys, renamed, because the
/// application refuses a bundle that carries the former ones.
enum IsiXLegacyInfoKey {
    static let filterClass = "IsiXLegacyFilterClass"
    static let pluginType = "IsiXLegacyPluginType"
    static let menuTitles = "IsiXLegacyMenuTitles"
    /// The XML-RPC methods the plugin answered through OsirixXMLRPCMessageNotification.
    static let xmlRPCMethods = "IsiXLegacyXMLRPCMethods"
}

/// Why the entry could not start the legacy plugin, or a command failed.
struct IsiXLegacyError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// The command placement and requirement of a legacy plugin type.
func IsiXLegacyPlacement(ofType type: String) -> (IsiXCommand.Placement, IsiXCommand.Requirement) {
    switch type.lowercased() {
    case "imagefilter", "fusionfilter": return (.imageFilters, .viewer)
    case "roitool": return (.roiTools, .viewer)
    case "database": return (.database, .none)
    default: return (.other, .none)
    }
}

/// The state of the ported plugin: its context, the viewers it was given and
/// the first failure of the command running.
@MainActor
final class IsiXLegacyState {
    static let shared = IsiXLegacyState()

    var context: IsiXPluginContext?
    private var sessions: [IsiXViewerID: IsiXLegacyViewerSession] = [:]
    private var invocation: IsiXCommandInvocation?
    private var failure: (any Error)?

    /// The session of a viewer, the same object for as long as the viewer is open.
    func session(for viewer: IsiXViewer) -> IsiXLegacyViewerSession {
        if let known = sessions[viewer.id], known.viewer.isOpen { return known }
        let session = IsiXLegacyViewerSession(viewer: viewer)
        sessions[viewer.id] = session
        IsiXLegacyViewerEvents.shared.sessionCreated(session)
        return session
    }

    /// The session of a viewer the plugin was given, if any.
    func knownSession(_ id: IsiXViewerID) -> IsiXLegacyViewerSession? { sessions[id] }

    /// The sessions of the viewers the plugin was given that are still open.
    var knownSessions: [IsiXLegacyViewerSession] { sessions.values.filter { $0.viewer.isOpen } }

    func forget(_ id: IsiXViewerID) {
        sessions.removeValue(forKey: id)?.invalidate()
    }

    func seriesReplaced(_ id: IsiXViewerID) {
        sessions[id]?.seriesReplaced()
    }

    /// The window to attach sheets to while a command runs on this viewer.
    func parentWindow(for session: IsiXLegacyViewerSession) -> NSWindow? {
        guard let invocation, invocation.viewer?.id == session.viewer.id else { return nil }
        return invocation.parentWindow
    }

    /// Notes the first failure of a call into the application; the command
    /// that runs throws it once the legacy code returns, and outside a command
    /// it is logged.
    func record(_ error: any Error) {
        if invocation != nil {
            if failure == nil { failure = error }
        } else {
            NSLog("%@: %@", context?.info.name ?? "IsiX legacy plugin", (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
    }

    func run(_ invocation: IsiXCommandInvocation, _ body: () -> Int) throws {
        self.invocation = invocation
        failure = nil
        defer { self.invocation = nil; failure = nil }
        let status = body()
        if let failure { throw failure }
        if status != 0 {
            throw IsiXLegacyError("\(invocation.command.title) ended with the error code \(status).")
        }
    }
}

/// The principal class of a ported plugin.
@MainActor
public final class IsiXLegacyPluginEntry: IsiXPlugin {
    private var filter: (any IsiXLegacyFilterHost)?
    private var observation: IsiXObservation?

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        let state = IsiXLegacyState.shared
        state.context = context
        let info = context.bundle.infoDictionary ?? [:]
        // A legacy plugin without an Info.plist, or whose Info.plist named no
        // principal class, leaves the name empty: its only PluginFilter is taken.
        let className = info[IsiXLegacyInfoKey.filterClass] as? String ?? ""
        guard let type = Self.filterClass(named: className, in: context.bundle) else {
            throw IsiXLegacyError(className.isEmpty
                ? "The plugin names no filter class under \(IsiXLegacyInfoKey.filterClass) and has not exactly one subclass of PluginFilter."
                : "The filter class \(className) is not in the plugin.")
        }
        guard let filter = type.init() as? any IsiXLegacyFilterHost else {
            throw IsiXLegacyError("The filter class \(className) is not a PluginFilter.")
        }
        self.filter = filter
        let titles = (info[IsiXLegacyInfoKey.menuTitles] as? [String]).flatMap { $0.isEmpty ? nil : $0 } ?? [context.info.name]
        let (placement, requirement) = IsiXLegacyPlacement(ofType: info[IsiXLegacyInfoKey.pluginType] as? String ?? "")
        observation = try context.observe([.viewerWillClose, .viewerOpened, .sliceChanged, .roiChanged]) { event in
            // The legacy notifications first: a closing viewer is still known to the kit.
            IsiXLegacyViewerEvents.shared.handle(event)
            switch event {
            case .viewerWillClose(let id): IsiXLegacyState.shared.forget(id)
            case .viewerOpened(let id): IsiXLegacyState.shared.seriesReplaced(id)
            default: break
            }
        }
        IsiXLegacyViewerEvents.shared.start(sink: filter as? any IsiXLegacyEventSink)
        filter.isixLegacyStart()
        try IsiXLegacyNetworkBridge.registerXMLRPCMethods(context)
        for (index, title) in titles.enumerated() {
            let command = IsiXCommand(id: "legacy-menu-\(index)", title: title, placement: placement, requirement: requirement)
            try context.register(command) { invocation in
                let session = invocation.viewer.map { IsiXLegacyState.shared.session(for: $0) }
                session?.reload()
                try IsiXLegacyState.shared.run(invocation) {
                    let status = filter.isixLegacyRun(menu: title, viewer: session)
                    session?.flush()
                    return status
                }
            }
        }
    }

    /// The legacy filter class, looked up in the plugin's own executable:
    /// another plugin may have a class of the same name. When the Info.plist
    /// names no class of the plugin, as some legacy plugins did, the plugin's
    /// only subclass of PluginFilter is taken, as the legacy application took
    /// the bundle's principal class.
    private static func filterClass(named name: String, in bundle: Bundle) -> NSObject.Type? {
        // A class is looked up by its symbol in the plugin's executable: the
        // runtime's lookup by name answers with one class when two images
        // define the same name.
        guard let path = bundle.executableURL?.path, let image = dlopen(path, RTLD_NOLOAD | RTLD_LAZY) else { return nil }
        defer { dlclose(image) }
        func ownClass(_ className: String) -> NSObject.Type? {
            guard let symbol = dlsym(image, "OBJC_CLASS_$_" + className) else { return nil }
            return unsafeBitCast(symbol, to: AnyClass.self) as? NSObject.Type
        }
        if !name.isEmpty, let named = ownClass(name), named.conforms(to: IsiXLegacyFilterHost.self) {
            return named
        }
        var count: UInt32 = 0
        let imageName = class_getImageName(IsiXLegacyViewerSession.self).map { String(cString: $0) } ?? path
        guard let names = objc_copyClassNamesForImage(imageName, &count) else { return nil }
        defer { free(UnsafeMutableRawPointer(mutating: names)) }
        var filters: [NSObject.Type] = []
        for index in 0..<Int(count) {
            guard let found = ownClass(String(cString: names[index])),
                  let superclass = class_getSuperclass(found) as? NSObject.Type, superclass.conforms(to: IsiXLegacyFilterHost.self) else { continue }
            filters.append(found)
        }
        if filters.count == 1 {
            if name.isEmpty {
                NSLog("%@: no filter class named; using %@", bundle.bundleURL.lastPathComponent, NSStringFromClass(filters[0]))
            } else {
                NSLog("%@: the filter class %@ is not in the plugin; using %@", bundle.bundleURL.lastPathComponent, name,
                      NSStringFromClass(filters[0]))
            }
            return filters[0]
        }
        return nil
    }

    public func deactivate() {
        IsiXLegacyViewerEvents.shared.stop()
        filter?.isixLegacyStop()
        // The legacy application kept a plugin's filter for as long as it ran.
        // The plugin's windows and observers point at it without a reference
        // of their own, and may still message it after this: a window left
        // open hears the viewers close when the application quits.
        if let filter { Self.retiredFilters.append(filter) }
        filter = nil
        observation = nil
        IsiXLegacyEventRelay.stop()
        IsiXLegacyDatabaseBridge.shared.removeTemporaryFiles()
    }

    private static var retiredFilters: [any IsiXLegacyFilterHost] = []
}
