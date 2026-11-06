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
import IsiXPluginKit
import os
import Synchronization

/// ROI Enhancement on the plugin API version 1: the time-attenuation curve
/// (minimum, mean and maximum) of each ROI of the current slice of a 4D
/// series, over its phases, in a window of the plugin's.
///
/// The curve follows the ROIs: a ROI added, moved or removed on the viewer
/// redraws it. When the viewer closes the window closes and the observation
/// ends, so nothing is called for that viewer afterwards.
public final class ROIEnhancementPlugin: IsiXPlugin, CustomStringConvertible {
    private let log = Logger(subsystem: "org.isix.pilot.roi-enhancement", category: "pilot")
    private let journal = Mutex<[String]>([])
    private var context: IsiXPluginContext?

    /// One open curve window per viewer.
    @MainActor
    private final class Session {
        let viewer: IsiXViewer
        /// Nil without a running application (a test host): nowhere to show it.
        let window: CurveWindowController?
        var observation: IsiXObservation?
        var refreshScheduled = false

        init(viewer: IsiXViewer, window: CurveWindowController?) {
            self.viewer = viewer
            self.window = window
        }
    }

    private var sessions: [IsiXViewerID: Session] = [:]

    public nonisolated var description: String { journal.withLock { $0.joined(separator: "\n") } }

    public init() {}

    public func activate(with context: IsiXPluginContext) throws {
        self.context = context
        try context.register(IsiXCommand(id: "roi-enhancement", title: "ROI Enhancement",
                                         placement: .roiTools, requirement: .viewer)) { [weak self] invocation in
            guard let viewer = invocation.viewer else { throw IsiXPluginError.viewerClosed }
            try self?.show(viewer)
        }
        note("activated \(context.info.identifier) \(context.info.version)")
    }

    public func deactivate() {
        for session in sessions.values { end(session) }
        sessions.removeAll()
        context = nil
    }

    private func note(_ line: String) {
        journal.withLock { $0.append(line) }
        log.notice("ROIEnhancement: \(line, privacy: .public)")
    }

    func show(_ viewer: IsiXViewer) throws {
        guard let context else { throw IsiXPluginError.pluginInactive }
        let curves = try EnhancementCurve.curves(in: viewer)
        let session: Session
        if let existing = sessions[viewer.id] {
            session = existing
        } else {
            let running = NSApp?.isRunning ?? false
            session = Session(viewer: viewer, window: running ? CurveWindowController(title: "ROI Enhancement") : nil)
            let id = viewer.id
            session.observation = try context.observe([.roiChanged, .viewerWillClose, .sliceChanged]) { [weak self] event in
                self?.handle(event, for: id)
            }
            sessions[id] = session
        }
        present(curves, in: session, reason: "computed")
        session.window?.showWindow(nil)
    }

    private func handle(_ event: IsiXEvent, for id: IsiXViewerID) {
        guard let session = sessions[id] else { return }
        switch event {
        case .viewerWillClose(let closing) where closing == id:
            end(session)
            sessions[id] = nil
            note("viewer closed: window closed, observation ended")
        case .roiChanged(let viewer, _, let change) where viewer == id && change != .selected:
            scheduleRefresh(session, id: id)
        case .sliceChanged(let viewer, _) where viewer == id:
            scheduleRefresh(session, id: id)
        default:
            break
        }
    }

    /// A drag sends many changes: recompute once per turn of the run loop.
    private func scheduleRefresh(_ session: Session, id: IsiXViewerID) {
        guard !session.refreshScheduled else { return }
        session.refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let session = self.sessions[id] else { return }
                session.refreshScheduled = false
                do {
                    self.present(try EnhancementCurve.curves(in: session.viewer), in: session, reason: "recomputed")
                } catch {
                    session.window?.curveView.curves = []
                    self.note("recompute: \(error.localizedDescription)")
                }
            }
        }
    }

    private func present(_ curves: [EnhancementCurve], in session: Session, reason: String) {
        session.window?.curveView.curves = curves
        for curve in curves {
            let values = curve.samples.map { String(format: "%.3f:%.4f/%.4f/%.4f", $0.time, $0.minimum, $0.mean, $0.maximum) }
            note("\(reason) \(curve.name) [t:min/mean/max] \(values.joined(separator: " "))")
        }
    }

    private func end(_ session: Session) {
        session.observation?.invalidate()
        session.observation = nil
        session.window?.close()
    }
}
