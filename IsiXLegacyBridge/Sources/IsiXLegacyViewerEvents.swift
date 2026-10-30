//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// The events of the viewers, as a legacy plugin got them: the notifications of
// Notifications.h, posted in the plugin's own notification center with the
// kit's ViewerController, DCMView and ROI objects, and -handleEvent:forViewer:
// of the filter. They come from the plugin API: its events (a viewer closing,
// another image shown, a ROI added, changed, selected or removed), the mouse
// and key events of the viewers' images, and an overlay over each image for
// the drawing notification. Nothing is asked of the application until the
// plugin observes a name of Notifications.h or answers -handleEvent:forViewer:.

import AppKit
import IsiXPluginKit

/// What the kit's PluginFilter does with the events, in Objective-C, where the
/// kit's ViewerController and ROI classes live.
@objc protocol IsiXLegacyEventSink: NSObjectProtocol {
    /// Whether the filter answers -handleEvent:forViewer:.
    @objc(isixTakesEvents) var takesEvents: Bool { get }
    /// Gives the event to -handleEvent:forViewer: and, for a click, posts
    /// the mouse-down notification; true when the plugin took the event.
    @objc(isixInput:session:) func input(_ input: IsiXLegacyInput, session: IsiXLegacyViewerSession) -> Bool
    @objc(isixViewerWillClose:) func viewerWillClose(_ session: IsiXLegacyViewerSession)
    @objc(isixSliceChanged:) func sliceChanged(_ session: IsiXLegacyViewerSession)
    /// `change` is added, modified, selected or removed.
    @objc(isixROI:change:session:) func roiChanged(_ identifier: String, change: String, session: IsiXLegacyViewerSession)
    @objc(isixDraw:session:) func draw(_ overlay: IsiXLegacyOverlay, session: IsiXLegacyViewerSession)
    /// Gives the viewers what the plugin changed, after an event it handled.
    @objc(isixFlush:) func flush(_ session: IsiXLegacyViewerSession)
}

/// A mouse or key event of a viewer's image, in the legacy terms.
@objc final class IsiXLegacyInput: NSObject {
    /// The position on the image with the centre of the first pixel at (0.5, 0.5).
    @objc let x: Double
    @objc let y: Double
    /// A press of the left button without Shift, Control, Option or Command:
    /// what the legacy application announced with the mouse-down notification.
    @objc let isPlainClick: Bool
    /// The event as AppKit would have given it, for -handleEvent:forViewer:.
    @objc let event: NSEvent?

    init(_ input: IsiXViewerInput) {
        x = input.location.x + 0.5
        y = input.location.y + 0.5
        let keys: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        isPlainClick = input.kind == .mouseDown && input.modifierFlags.intersection(keys).isEmpty
        switch input.kind {
        case .keyDown:
            event = NSEvent.keyEvent(with: .keyDown, location: input.locationInWindow, modifierFlags: input.modifierFlags,
                                     timestamp: input.timestamp, windowNumber: input.windowNumber, context: nil,
                                     characters: input.characters ?? "", charactersIgnoringModifiers: input.characters ?? "",
                                     isARepeat: false, keyCode: input.keyCode ?? 0)
        default:
            let type: NSEvent.EventType = input.kind == .mouseDown ? .leftMouseDown : input.kind == .mouseUp ? .leftMouseUp : .leftMouseDragged
            event = NSEvent.mouseEvent(with: type, location: input.locationInWindow, modifierFlags: input.modifierFlags,
                                       timestamp: input.timestamp, windowNumber: input.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: input.clickCount, pressure: 1)
        }
    }
}

/// The drawing notification's context: a Core Graphics context over the
/// image, in its pixels with the centre of the first pixel at (0.5, 0.5).
@objc final class IsiXLegacyOverlay: NSObject {
    @objc let context: CGContext
    /// The length of one point of the screen, in pixels.
    @objc let pointSize: Double
    @objc let spacingX: Double
    @objc let spacingY: Double

    init(context: CGContext, pointSize: Double, spacingX: Double, spacingY: Double) {
        self.context = context
        self.pointSize = pointSize
        self.spacingX = spacingX
        self.spacingY = spacingY
    }
}

extension IsiXLegacyViewerSession {
    /// Redraws the viewer.
    @objc nonisolated func redraw() {
        IsiXLegacyOnMain { viewer.setNeedsDisplay() }
    }
}

extension IsiXLegacyROIState {
    /// The identifier of the application's ROI, as the plugin API gives it.
    @objc var hostIdentifier: String? { roi?.id.description }
    @objc var hostSlice: Int { roi?.slice ?? -1 }
    @objc var hostPhase: Int { roi?.phase ?? -1 }
}

@MainActor
@objc final class IsiXLegacyViewerEvents: NSObject {
    static let shared = IsiXLegacyViewerEvents()

    /// Names of Notifications.h the kit posts.
    enum Name {
        static let mouseDown = "mouseDown", closeViewer = "CloseViewerNotification", currentImage = "DCMUpdateCurrentImage"
        static let addROI = "addROI", roiChange = "roiChange", roiSelected = "roiSelected", removeROI = "removeROI"
        static let draw = "PLUGINdrawObjects", updateView = "updateView"
        static let roiNames: Set<String> = [addROI, roiChange, roiSelected, removeROI]
    }

    private weak var sink: (any IsiXLegacyEventSink)?
    /// The names the plugin observes.
    private var observed = Set<String>()
    private var input: IsiXObservation?
    private var inputKinds: IsiXInputKinds = []
    private var overlays: [IsiXViewerID: IsiXObservation] = [:]
    private var pendingSlices: [IsiXViewerID] = []
    private var pendingROIs: [(IsiXViewerID, IsiXROIID, IsiXROIChange)] = []
    private var deliveryScheduled = false

    private var context: IsiXPluginContext? { IsiXLegacyState.shared.context }

    func start(sink: (any IsiXLegacyEventSink)?) {
        self.sink = sink
        if sink?.takesEvents == true { intercept(.all) }
    }

    /// Forgets what the plugin observed and what it was given: a plugin
    /// activated again in the same process observes its names anew, and each
    /// first observation must ask the application for its events again.
    func stop() {
        input = nil
        inputKinds = []
        overlays.removeAll()
        observed.removeAll()
        pendingSlices.removeAll()
        pendingROIs.removeAll()
        sink = nil
    }

    /// The plugin observes `name` in its notification center.
    @objc nonisolated static func notificationObserved(_ name: String) {
        IsiXLegacyOnMain { shared.observe(name) }
    }

    /// The plugin posted the redraw notification.
    @objc nonisolated static func updateViews() {
        IsiXLegacyOnMain {
            for session in IsiXLegacyState.shared.knownSessions { session.flush() }
        }
    }

    private func observe(_ name: String) {
        guard observed.insert(name).inserted else { return }
        switch name {
        case Name.mouseDown: intercept(.mouseDown)
        case Name.draw: for session in IsiXLegacyState.shared.knownSessions { addOverlay(to: session) }
        default: IsiXLegacyEventRelay.notificationObserved(name)
        }
    }

    /// A session the kit made for a viewer.
    func sessionCreated(_ session: IsiXLegacyViewerSession) {
        if observed.contains(Name.draw) { addOverlay(to: session) }
    }

    // MARK: input

    private func intercept(_ kinds: IsiXInputKinds) {
        guard !inputKinds.isSuperset(of: kinds), let context else { return }
        inputKinds.formUnion(kinds)
        input = try? context.interceptInput(inputKinds) { input in
            IsiXLegacyViewerEvents.shared.take(input)
        }
    }

    private func take(_ input: IsiXViewerInput) -> Bool {
        guard let sink, let viewer = (try? context?.viewer(withID: input.viewerID)) ?? nil else { return false }
        let session = IsiXLegacyState.shared.session(for: viewer)
        let taken = sink.input(IsiXLegacyInput(input), session: session)
        // What the plugin did with a click or a key reaches the viewer now; a
        // drag waits for the button to go up.
        if input.kind != .mouseDragged { sink.flush(session) }
        return taken
    }

    // MARK: drawing

    private func addOverlay(to session: IsiXLegacyViewerSession) {
        let id = session.viewer.id
        guard overlays[id] == nil, session.viewer.isOpen else { return }
        overlays[id] = try? session.viewer.addOverlay { [weak session] overlay in
            guard let session, let sink = IsiXLegacyViewerEvents.shared.sink else { return }
            // The legacy pixel coordinates put the centre of the first pixel at (0.5, 0.5).
            overlay.cgContext.translateBy(x: -0.5, y: -0.5)
            let info = session.info(slice: overlay.position.slice, phase: overlay.position.phase)
            sink.draw(IsiXLegacyOverlay(context: overlay.cgContext, pointSize: Double(overlay.pointSize),
                                        spacingX: info?.spacingX ?? 0, spacingY: info?.spacingY ?? 0), session: session)
        }
    }

    // MARK: events of the plugin API

    /// An event of the plugin API; a viewer closing is announced at once,
    /// before the kit forgets it, the others on the next turn of the run
    /// loop, once the change that caused them is complete.
    func handle(_ event: IsiXEvent) {
        switch event {
        case .viewerWillClose(let id):
            overlays[id] = nil
            if observed.contains(Name.closeViewer), let session = IsiXLegacyState.shared.knownSession(id) {
                sink?.viewerWillClose(session)
            }
        case .sliceChanged(let id, _):
            guard observed.contains(Name.currentImage) else { return }
            if !pendingSlices.contains(id) { pendingSlices.append(id) }
            scheduleDelivery()
        case .roiChanged(let id, let roi, let change):
            guard !observed.isDisjoint(with: Name.roiNames) else { return }
            if let last = pendingROIs.last, last.0 == id, last.1 == roi, last.2 == change { return }
            pendingROIs.append((id, roi, change))
            scheduleDelivery()
        default:
            break
        }
    }

    private func scheduleDelivery() {
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { IsiXLegacyViewerEvents.shared.deliver() }
        }
    }

    private func deliver() {
        deliveryScheduled = false
        let slices = pendingSlices, rois = pendingROIs
        pendingSlices = []
        pendingROIs = []
        guard let sink else { return }
        func session(_ id: IsiXViewerID) -> IsiXLegacyViewerSession? {
            guard let viewer = (try? context?.viewer(withID: id)) ?? nil else { return nil }
            return IsiXLegacyState.shared.session(for: viewer)
        }
        for (id, roi, change) in rois {
            guard let session = session(id) else { continue }
            let name: String
            switch change {
            case .added: name = "added"
            case .modified: name = "modified"
            case .selected: name = "selected"
            case .removed: name = "removed"
            @unknown default: continue
            }
            sink.roiChanged(roi.description, change: name, session: session)
        }
        for id in slices {
            if let session = session(id) { sink.sliceChanged(session) }
        }
    }
}
