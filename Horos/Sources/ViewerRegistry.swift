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
import IsiXPreferences
import Synchronization

/// The register of the process's 2D viewers: every viewer from the set-up of
/// its window to its closing, in the order they opened, and which of them are
/// displayed.
///
/// Any thread asks it: the drawing of a view reads the displayed viewers under
/// its own lock, and the XML-RPC and export threads read the list. So the
/// entries are kept under a mutex, and what they say of a window (closing,
/// full screen) is published by the viewer on the main actor when it changes:
/// no reader touches a window from another thread. One register per process,
/// held by the process graph.
nonisolated final class ViewerRegistry: Sendable {

    /// The entries {viewer, closing, full screen}: the viewers in the order they
    /// were registered, retained once each time (a viewer set up twice is there
    /// twice until it closes), and the state their windows published, by
    /// identity. The readers, which come at every draw, take the list itself
    /// while no window is closing or full screen.
    private struct State: Sendable {
        var viewers: [ViewerController] = []
        /// The window closed: the viewer is on its way out.
        var closing: Set<ObjectIdentifier> = []
        /// The viewer's window is the full screen one.
        var fullScreen: Set<ObjectIdentifier> = []
        /// No list existed before the first registration.
        var hasRegistered = false
        /// Every viewer is being closed at once.
        var isClosingAll = false
    }

    private let state = Mutex(State())

    /// Registrations less closings; a closing counts even for a viewer that
    /// was not registered. Read without the lock, at every draw.
    private let registeredCount = Atomic<Int32>(0)

    init() {}

    // MARK: - Registration

    /// Registers a viewer as its window is set up; `isFullScreen` is its window's state.
    func register(_ viewer: ViewerController, isFullScreen: Bool) {
        state.withLock { state in
            registeredCount.add(1, ordering: .sequentiallyConsistent)
            state.hasRegistered = true
            state.viewers.append(viewer)
            if isFullScreen {
                state.fullScreen.insert(ObjectIdentifier(viewer))
            } else {
                state.fullScreen.remove(ObjectIdentifier(viewer))
            }
        }
    }

    /// Unregisters a closed viewer, every time it was registered; answers how many are left.
    func unregister(_ viewer: ViewerController) -> Int32 {
        state.withLock { state in
            state.viewers.removeAll { $0 === viewer }
            if !state.viewers.contains(where: { $0 === viewer }) {
                state.closing.remove(ObjectIdentifier(viewer))
                state.fullScreen.remove(ObjectIdentifier(viewer))
            }
            return registeredCount.subtract(1, ordering: .sequentiallyConsistent).newValue
        }
    }

    /// The window of `viewer` is closing; published on the main actor.
    func viewerWillClose(_ viewer: ViewerController) {
        state.withLock { state in
            if state.viewers.contains(where: { $0 === viewer }) {
                state.closing.insert(ObjectIdentifier(viewer))
            }
        }
    }

    /// The window of the viewer `viewer` became, or stopped being, the full
    /// screen one; published on the main actor, by identity, so that a viewer
    /// that is being freed may publish too.
    func setFullScreen(_ isFullScreen: Bool, for viewer: ObjectIdentifier) {
        state.withLock { state in
            if isFullScreen {
                if state.viewers.contains(where: { ObjectIdentifier($0) == viewer }) {
                    state.fullScreen.insert(viewer)
                }
            } else {
                state.fullScreen.remove(viewer)
            }
        }
    }

    // MARK: - Reading, from any thread

    /// How many viewers are registered.
    var count: Int32 {
        registeredCount.load(ordering: .sequentiallyConsistent)
    }

    /// The registered viewers, on screen and off screen; nil before the first registration.
    var viewers: [ViewerController]? {
        state.withLock { $0.hasRegistered ? $0.viewers : nil }
    }

    /// The registered viewers whose window is neither closing nor the full screen one.
    var displayedViewers: [ViewerController] {
        var shown = state.withLock { state in
            state.closing.isEmpty && state.fullScreen.isEmpty ? state.viewers
                : state.viewers.filter { !state.closing.contains(ObjectIdentifier($0)) && !state.fullScreen.contains(ObjectIdentifier($0)) }
        }
        // The viewer's own closing flag is read outside the lock, a plain field:
        // a series replaced in its window raises it for a while, without closing it.
        if shown.contains(where: { $0.windowWillClose() }) {
            shown.removeAll { $0.windowWillClose() }
        }
        return shown
    }

    /// Whether every viewer is being closed at once: the viewers made main in
    /// the meantime do not refresh.
    var isClosingAllWindows: Bool {
        state.withLock { $0.isClosingAll }
    }

    // MARK: - The windows on screen, on the main actor

    /// The visible viewers of `screen` (all screens when nil) that are not
    /// closing, front first.
    @MainActor func displayedViewers(on screen: NSScreen?) -> [ViewerController] {
        NSApp.orderedWindows.compactMap { window in
            guard let viewer = window.windowController as? ViewerController, window.isVisible else { return nil }
            guard screen == nil || (window.screen as NSObject?)?.isEqual(screen) == true else { return nil }
            return viewer.windowWillClose() ? nil : viewer
        }
    }

    /// The front visible viewer of `screen` (any screen when nil) that is not
    /// closing. AppKit's orderedWindows can lag the key and main viewers
    /// during activation, so the key window and then the main window are asked
    /// first.
    @MainActor func frontMostDisplayedViewer(on screen: NSScreen?) -> ViewerController? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        for window in windows {
            guard window.isVisible, let viewer = window.windowController as? ViewerController else { continue }
            if let screen, (window.screen as NSObject?)?.isEqual(screen) != true { continue }
            if !viewer.windowWillClose() { return viewer }
        }
        return nil
    }

    /// Each series of the displayed viewers once, with the first of its
    /// viewers in the order the window colours are given out.
    @MainActor func displayedSeriesInColourOrder() -> [(series: AnyObject, viewer: ViewerController)] {
        var shown: [(series: AnyObject, viewer: ViewerController)] = []
        for case let viewer as ViewerController in ViewerWindowColors.viewersInColorOrder(displayedViewers) {
            guard let series = viewer.imageView()?.seriesObj() as AnyObject? else { continue }
            if !shown.contains(where: { $0.series === series }) {
                shown.append((series, viewer))
            }
        }
        return shown
    }

    // MARK: - Closing every viewer

    /// Closes every displayed viewer, saving the layout first when the
    /// preference asks for it; `cancelDelayedTiling` drops a tiling scheduled
    /// after a delay, before and after.
    @MainActor func closeAllWindows(in processGraph: ProcessGraph, cancelDelayedTiling: () -> Void) {
        let started = state.withLock { state in
            if state.isClosingAll { return false }
            state.isClosingAll = true
            return true
        }
        guard started else { return }

        cancelDelayedTiling()

        let viewers = displayedViewers
        let preferences = processGraph.preferences
        if !viewers.isEmpty {
            if preferences[ViewerPreferences.automaticWorkspaceSave] {
                ViewerController.saveWindowsState()
            }

            // The sender was the class, as the former class method sent itself.
            let sender = ViewerController.self
            for viewer in viewers {
                if viewer.fullScreenON() {
                    viewer.fullScreenMenu(sender)
                }
                viewer.window?.orderOut(sender)
            }

            for viewer in viewers where !viewer.windowWillClose() {
                viewer.window?.close() // performClose: self
            }
        }

        cancelDelayedTiling()

        state.withLock { $0.isClosingAll = false }

        if !preferences[ViewerPreferences.keepsListPODComparativesChoice] {
            preferences.set(true, for: ViewerPreferences.listPODComparativesIn2DViewer)
        }

        processGraph.currentBrowser?.selectDatabaseOutline()
    }
}
