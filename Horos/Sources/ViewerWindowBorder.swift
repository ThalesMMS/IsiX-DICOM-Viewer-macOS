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
import IsiXImaging

/// The frame around the views of a 2D window and around the thumbnail of the
/// series it shows, as WindowFrameRule (IsiXImaging) rules it: the image and
/// the series list ask here, so they draw the same frame or none.
///
/// It gives the rule what it goes by: how many 2D windows are on screen, which
/// the register counts, and the study the window was opened with and the one
/// it shows, which the window's graph keeps. It also has the windows drawn
/// again when one of those changes without the window being touched: another
/// window goes to the Dock or comes back, closes, or the active Space changes.
@MainActor
@objc(HorosViewerWindowBorder)
public final class ViewerWindowBorder: NSObject {

    // MARK: - The frame

    /// The colour of the frame of a view of `viewer`'s window: its study's on
    /// the active view (`active`: the key view of the front window), the
    /// neutral one on the others; nil where no frame is drawn.
    @objc(colorForViewer:active:)
    public static func color(for viewer: ViewerController, active: Bool) -> NSColor? {
        guard let graph = viewer.sessionGraph else { return nil }
        switch WindowFrameRule.frame(severalOnScreen: graph.registry.severalViewersAreOnScreen, isActive: active,
                                     study: SeriesListIdentification.study(of: viewer), studies: graph.windowStudies) {
        case .none: return nil
        case .neutral: return SeriesListIdentification.neutralColor
        case .study(let study): return SeriesListIdentification.color(of: study)
        }
    }

    // MARK: - The study of the window

    /// `viewer` shows a series of `study`, wherever it came from. The first
    /// study of a window is the one it was opened with; a later one changes
    /// the frame when it is another study, or the opening one again.
    @objc(studyShown:inViewer:)
    public static func studyShown(_ study: DicomStudy?, in viewer: ViewerController) {
        guard let graph = viewer.sessionGraph else { return }
        let before = graph.windowStudies
        graph.windowStudies.show(study.flatMap { study in study.studyInstanceUID.map { StudyReference(uid: $0, date: study.date) } })
        watchActiveSpace(for: graph)
        if graph.windowStudies != before && (before.showsAnotherStudy || graph.windowStudies.showsAnotherStudy) {
            windowsChanged(among: [viewer])
        }
    }

    /// An opening the user asked for (from the database, a node, the recent
    /// studies, a hanging protocol) put its series in the window of `viewer`
    /// instead of a new one: the study shown is the one the window was opened
    /// with from now on. The series a viewer takes from its own lists and
    /// steps do not come here.
    @objc(viewerReopened:)
    public static func reopened(_ viewer: ViewerController) {
        guard let graph = viewer.sessionGraph, graph.windowStudies.showsAnotherStudy else { return }
        graph.windowStudies.reopen()
        windowsChanged(among: [viewer])
    }

    // MARK: - Drawing again

    /// What `viewers` go by changed: their views draw their frames again and
    /// their lists recolour the cell that carries one.
    @objc(windowsChangedAmong:)
    public static func windowsChanged(among viewers: [ViewerController]) {
        for viewer in viewers where !viewer.windowWillClose() {
            for case let view as DCMView in viewer.imageViews() ?? [] {
                view.needsDisplay = true
            }
            viewer.seriesListPresenter.build(showSelected: false, selectionOnly: true)
        }
    }

    /// The window of `viewer` closed: it stops watching the Spaces, and the
    /// `remaining` windows, one fewer on screen, draw their frames again.
    @objc(windowClosed:remaining:)
    public static func windowClosed(_ viewer: ViewerController, remaining: [ViewerController]) {
        if let observation = viewer.sessionGraph?.activeSpaceObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
            viewer.sessionGraph?.activeSpaceObservation = nil
        }
        windowsChanged(among: remaining)
    }

    /// A window on another Space is not on screen: when the Space shown
    /// changes, the viewer of `graph` draws its frame again. Each window
    /// watches for itself, until it closes.
    private static func watchActiveSpace(for graph: ViewerSessionGraph) {
        guard graph.activeSpaceObservation == nil else { return }
        graph.activeSpaceObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak graph] _ in
            MainActor.assumeIsolated {
                if let viewer = graph?.viewer { windowsChanged(among: [viewer]) }
            }
        }
    }
}
