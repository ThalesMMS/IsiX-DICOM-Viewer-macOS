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
import IsiXPluginLoading
@_spi(IsiXHost) import IsiXPluginKit

/// The application's side of the plugin API version 1: it loads `.isixplugin`
/// bundles that IsiXPluginLoading accepted, keeps their runtimes, puts their
/// commands in the plugin menus, forwards viewer, ROI and database
/// notifications to them as events, and reaches viewers, the database and
/// the network through adapters, so that no class of the application reaches
/// a plugin.
///
/// Everything runs on the main thread, where the plugin manager loads plugins
/// and builds the menus.
@MainActor
@objc(IsiXPluginHost)
// IsiXNetworkBackend is implemented in IsiXNetworkAdapter.swift; it is
// declared here, where the class is, because it requires Sendable.
final class IsiXPluginHost: NSObject, IsiXHostBackend, IsiXNetworkBackend {
    @objc static let shared = IsiXPluginHost()

    let identities = IsiXObjectIdentities()
    private(set) var runtimes: [IsiXPluginRuntime] = []
    private var observers: [NSObjectProtocol] = []
    private weak var filtersMenu: NSMenu?
    private weak var roisMenu: NSMenu?
    private weak var othersMenu: NSMenu?
    private weak var databaseMenu: NSMenu?
    private var menusBuilt = false
    private var menuRebuildScheduled = false

    private override init() {
        super.init()
    }

    // MARK: loading

    /// The outcome of loading one bundle, for the plugin manager's record.
    struct Outcome {
        enum State { case loaded, incompatible, failed }
        var state: State
        var reason: String
    }

    /// Inspects the bundle, and loads, resolves and activates it only if the
    /// inspection found nothing wrong. The caller has checked protected mode
    /// and the signature, and marks the bundle as loading for crash recovery.
    func loadPlugin(at url: URL) -> Outcome {
        let inspection = PluginInspector().inspect(bundleAt: url)
        guard inspection.isLoadable, let manifest = inspection.manifest else {
            return Outcome(state: .incompatible, reason: inspection.summary)
        }
        if runtimes.contains(where: { $0.info.identifier == manifest.identifier }) {
            return Outcome(state: .incompatible,
                           reason: "Another plugin with the identifier \(manifest.identifier) is already loaded. Remove the duplicate and restart the application.")
        }
        guard let bundle = Bundle(url: url) else {
            return Outcome(state: .incompatible, reason: "The plugin bundle could not be opened. Reinstall a complete copy from its author.")
        }
        var loadError: NSError?
        guard PluginManagerCAPILoadBundle(bundle, &loadError) else {
            return Outcome(state: .failed, reason: loadError?.localizedDescription ?? "The bundle loader refused the plugin.")
        }
        let executable = url.appendingPathComponent("Contents/MacOS", isDirectory: true).appendingPathComponent(manifest.executableName)
        let entry: any IsiXPlugin.Type
        do {
            entry = try IsiXPluginRuntime.resolveEntry(named: manifest.principalClass, executableURL: executable)
        } catch {
            return Outcome(state: .incompatible, reason: error.message)
        }
        let info = IsiXPluginInfo(identifier: manifest.identifier, name: manifest.name, version: manifest.version,
                                  bundleURL: url, capabilities: Set(manifest.capabilities.map(IsiXCapability.init(rawValue:))))
        let runtime = IsiXPluginRuntime(info: info, bundle: bundle, entry: entry, host: self)
        // At the same boundary as the commands: an exception that escapes the
        // plugin's activation fails the plugin, which is not loaded.
        switch runtime.activateGuarded() {
        case .ran:
            break
        case .failed(let error):
            NSLog("IsiX plugin %@ refused to activate: %@", manifest.identifier, String(describing: error))
            return Outcome(state: .failed, reason: "The plugin failed to start: \(IsiXUserMessage(for: error)) Obtain an updated plugin from its author.")
        case .raised(let exception):
            NSLog("IsiX plugin %@ raised %@ while activating; the application caught it", manifest.identifier, exception.description)
            return Outcome(state: .failed, reason: "The plugin stopped with \(exception) while starting, and was not loaded. "
                           + "Obtain an updated plugin from its author.")
        }
        runtimes.append(runtime)
        installObservers()
        NSLog("Registering IsiX plugin %@ %@ (API %ld) from %@", manifest.identifier, manifest.version, manifest.apiVersion, url.path)
        return Outcome(state: .loaded, reason: "")
    }

    /// Deactivates every plugin, once, before the application quits.
    func deactivateAll() {
        for runtime in runtimes { runtime.deactivate() }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    func runtime(identifier: String) -> IsiXPluginRuntime? {
        runtimes.first { $0.info.identifier == identifier }
    }

    // MARK: menus

    /// Adds the commands of the active plugins to the menus the plugin
    /// manager builds, and remembers the menus to rebuild them when a plugin
    /// adds or removes a command later.
    func addMenuItems(filters: NSMenu?, rois: NSMenu?, others: NSMenu?, database: NSMenu?) {
        filtersMenu = filters
        roisMenu = rois
        othersMenu = others
        databaseMenu = database
        menusBuilt = true
        for runtime in runtimes where runtime.state == .active {
            for command in runtime.commands {
                let item = NSMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [runtime.info.identifier, command.id] as NSArray
                let menu: NSMenu?
                switch command.placement {
                case .imageFilters: menu = filters
                case .roiTools: menu = rois
                case .database: menu = database
                default: menu = others
                }
                menu?.addItem(item)
            }
        }
    }

    private func command(of item: NSMenuItem) -> (IsiXPluginRuntime, String)? {
        guard let pair = item.representedObject as? [String], pair.count == 2,
              let runtime = runtime(identifier: pair[0]) else { return nil }
        return (runtime, pair[1])
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let (runtime, id) = command(of: item) else { return false }
        return runtime.canRun(commandID: id, frontmostViewerOpen: frontmostViewer() != nil)
    }

    @objc(runCommand:) func runCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let (runtime, id) = command(of: item) else { return }
        run(runtime: runtime, commandID: id)
    }

    /// Runs a command; a thrown error is shown to the user and logged, and so
    /// is an exception that escaped the plugin, which is also recorded in the
    /// plugin manager's loading details. The plugin stays loaded, as it did
    /// when the former plugin manager caught an exception of a filter.
    @discardableResult
    func run(runtime: IsiXPluginRuntime, commandID: String) -> Error? {
        let error: any Error
        let message: String
        switch perform(runtime: runtime, commandID: commandID) {
        case .ran:
            return nil
        case .failed(let failure):
            error = failure
            message = IsiXUserMessage(for: failure)
        case .raised(let exception):
            error = exception
            message = Self.exceptionMessage(exception, command: runtime.title(ofCommand: commandID))
        }
        HorosAlertPanel.runCritical(title: NSLocalizedString("Plugins", comment: ""),
                                    message: "\(runtime.info.name): \(message)",
                                    defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        return error
    }

    /// Runs a command at the boundary with the plugin's code, logs a failure,
    /// and records an exception in the plugin manager's loading details.
    private func perform(runtime: IsiXPluginRuntime, commandID: String) -> IsiXCommandOutcome {
        let outcome = runtime.runGuarded(commandID: commandID)
        switch outcome {
        case .ran:
            break
        case .failed(let error):
            NSLog("IsiX plugin %@ command %@ failed: %@", runtime.info.identifier, commandID, String(describing: error))
        case .raised(let exception):
            NSLog("IsiX plugin %@ command %@ raised %@; the application caught it", runtime.info.identifier, commandID,
                  exception.description)
            PluginManagerCAPIRecordLoad(runtime.info.bundleURL.path, NSLocalizedString("Command failed", comment: ""),
                                        Self.exceptionMessage(exception, command: runtime.title(ofCommand: commandID)))
        }
        return outcome
    }

    private static func exceptionMessage(_ exception: IsiXPluginException, command: String) -> String {
        "The command \"\(command)\" stopped with \(exception). The application caught it and the plugin stays loaded, "
            + "but what the command left undone is lost. Report this to the plugin's author."
    }

    func commandsDidChange() {
        // Commands registered while the plugins load go in when the menus are
        // first built; a change after that rebuilds them once.
        guard menusBuilt, !menuRebuildScheduled else { return }
        menuRebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuRebuildScheduled = false
                PluginManager.setMenus(self.filtersMenu, self.roisMenu, self.othersMenu, self.databaseMenu)
            }
        }
    }

    // MARK: viewers

    private func adapter(for viewer: ViewerController) -> IsiXViewerAdapter {
        IsiXViewerAdapter(viewer: viewer, identities: identities)
    }

    private func displayedViewers() -> [ViewerController] {
        ((ViewerController.getDisplayed2DViewers() as NSArray?) ?? []).compactMap { $0 as? ViewerController }
    }

    func frontmostViewer() -> (any IsiXViewerBackend)? {
        guard let viewer = ViewerController.frontMostDisplayed2DViewer() else { return nil }
        let adapter = adapter(for: viewer)
        return adapter.isOpen ? adapter : nil
    }

    func openViewers() -> [any IsiXViewerBackend] {
        var viewers = displayedViewers()
        if let front = ViewerController.frontMostDisplayed2DViewer(), let index = viewers.firstIndex(of: front) {
            viewers.insert(viewers.remove(at: index), at: 0)
        }
        return viewers.map(adapter(for:)).filter(\.isOpen)
    }

    func viewer(withID id: IsiXViewerID) -> (any IsiXViewerBackend)? {
        displayedViewers().first { identities.knownID(of: $0) == id }.map(adapter(for:)).flatMap { $0.isOpen ? $0 : nil }
    }

    func parentWindow(forViewer id: IsiXViewerID?) -> NSWindow? {
        if let id, let viewer = displayedViewers().first(where: { identities.knownID(of: $0) == id }) {
            return viewer.window
        }
        return BrowserController.currentBrowser()?.window
    }

    // MARK: events

    /// Forwards the application's notifications as events. Installed when the
    /// first plugin activates: without version 1 plugins nothing is observed.
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { note in
                nonisolated(unsafe) let note = note
                if Thread.isMainThread {
                    MainActor.assumeIsolated { handler(note) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { handler(note) } }
                }
            })
        }
        observe(.OsirixViewerControllerDidLoadImages) { [weak self] note in
            guard let self, let viewer = note.object as? ViewerController else { return }
            self.deliver(.viewerOpened(self.identities.id(of: viewer)))
        }
        // The window closing, not OsirixCloseViewer: a viewer posts that one
        // too when it replaces its series and stays open.
        observe(NSWindow.willCloseNotification) { [weak self] note in
            guard let self, let viewer = (note.object as? NSWindow)?.windowController as? ViewerController else { return }
            let id = self.identities.id(of: viewer)
            guard !self.identities.isClosed(id) else { return }
            // From now on every handle of this viewer throws viewerClosed.
            self.identities.markClosed(id)
            self.deliver(.viewerWillClose(id))
        }
        observe(.OsirixDCMUpdateCurrentImage) { [weak self] note in
            guard let self, let view = note.object as? DCMView,
                  let viewer = view.windowController() as? ViewerController, viewer.imageView() === view else { return }
            let id = self.identities.id(of: viewer)
            guard !self.identities.isClosed(id) else { return }
            self.deliver(.sliceChanged(id, IsiXSlicePosition(slice: Int(view.curImage), phase: Int(viewer.curMovieIndex()))))
        }
        // ROI notifications: the viewer is found by looking the ROI up in the
        // open viewers' lists, never through the ROI's view, which the ROI
        // does not retain and which can be gone.
        func roiEvent(_ name: Notification.Name, _ change: IsiXROIChange, _ roiOf: @escaping @MainActor (Notification) -> ROI?) {
            observe(name) { [weak self] note in
                guard let self, let roi = roiOf(note), let viewer = self.viewer(containing: roi) else { return }
                let viewerID = self.identities.id(of: viewer)
                guard !self.identities.isClosed(viewerID) else { return }
                self.deliver(.roiChanged(viewerID, self.identities.id(of: roi, in: viewerID), change))
            }
        }
        roiEvent(.OsirixAddROI, .added) { ($0.userInfo?["ROI"] as? ROI) }
        roiEvent(.OsirixROIChange, .modified) { $0.object as? ROI }
        roiEvent(.OsirixROISelected, .selected) { $0.object as? ROI }
        // A removal can come from the ROI's -dealloc: only its address is
        // read, and only a ROI a plugin was told about is reported.
        observe(.OsirixRemoveROI) { [weak self] note in
            guard let self, let object = note.object as AnyObject? else { return }
            let address = IsiXObjectIdentities.address(of: object)
            guard let (roiID, viewerID) = self.identities.owner(ofROIAt: address) else { return }
            self.identities.forgetROI(at: address)
            guard !self.identities.isClosed(viewerID) else { return }
            self.deliver(.roiChanged(viewerID, roiID, .removed))
        }
        // The plugins' overlays, drawn as a viewer draws its ROIs.
        observe(.HorosDrawObjectsCanvas) { [weak self] note in
            self?.drawOverlays(note)
        }
        // Images added to the database (IsiXNetworkAdapter.swift).
        observe(.OsirixAddToDB) { [weak self] note in self?.deliverImagesAdded(note, complete: false) }
        observe(.OsirixAddToDBComplete) { [weak self] note in self?.deliverImagesAdded(note, complete: true) }
        observers.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.deactivateAll() }
        })
    }

    /// The open 2D viewer whose ROI lists hold `roi`.
    private func viewer(containing roi: ROI) -> ViewerController? {
        for viewer in displayedViewers() {
            for phase in 0..<max(Int(viewer.maxMovieIndex()), 1) {
                for case let list as NSArray in (viewer.roiList(phase) as NSArray?) ?? [] where list.indexOfObjectIdentical(to: roi) != NSNotFound {
                    return viewer
                }
            }
        }
        return nil
    }

    private func deliver(_ event: IsiXEvent) {
        for runtime in runtimes { runtime.deliver(event) }
    }

    // MARK: diagnostics

    /// The active plugins, their commands and what they report, one per
    /// line, for the log and for checks run through the debugger.
    @objc func pluginsDescription() -> String {
        runtimes.map { runtime in
            "\(runtime.info.identifier) \(runtime.state) commands \(runtime.commands.map(\.id)) observations \(runtime.observationCount) "
                + "tasks \(runtime.runningTaskCount)\n" + (runtime.instance.map { String(describing: $0) } ?? "")
        }.joined(separator: "\n")
    }

    /// The object of an active plugin, for checks run through the debugger
    /// that call what a plugin offers besides its commands.
    @objc(pluginInstanceWithIdentifier:) func pluginInstance(identifier: String) -> AnyObject? {
        runtime(identifier: identifier)?.instance
    }

    /// Runs a command without the menu or alerts, at the same boundary, for
    /// checks run through the debugger.
    @objc(runCommand:ofPlugin:) func runCommand(_ commandID: String, ofPlugin identifier: String) -> String {
        guard let runtime = runtime(identifier: identifier) else { return "no plugin \(identifier)" }
        switch perform(runtime: runtime, commandID: commandID) {
        case .ran: return "ran \(commandID)"
        case .failed(let error): return "\(commandID) failed: \(IsiXUserMessage(for: error))"
        case .raised(let exception): return "\(commandID) raised \(exception)"
        }
    }
}
