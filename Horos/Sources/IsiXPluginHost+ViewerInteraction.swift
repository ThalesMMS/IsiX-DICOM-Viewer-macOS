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
@_spi(IsiXHost) import IsiXPluginKit

/// The plugins' drawing over a 2D viewer's image and their mouse and key
/// handlers. Only the image view of an open 2D viewer takes part; nothing is
/// done while no plugin of version 1 asked for it.
extension IsiXPluginHost {
    /// The 2D viewer whose image view `view` is, and its identifier, while it is open.
    private func viewer(ofImageView view: DCMView) -> (ViewerController, IsiXViewerID)? {
        guard let viewer = view.windowController() as? ViewerController, viewer.imageView() === view else { return nil }
        let id = identities.id(of: viewer)
        return identities.isClosed(id) ? nil : (viewer, id)
    }

    /// Gives a mouse or key event of a viewer's image to the plugins that
    /// take its kind, before the viewer acts on it; true when a plugin took it.
    @objc(takesViewerInput:inView:)
    func takesViewerInput(_ event: NSEvent, in view: DCMView) -> Bool {
        guard !runtimes.isEmpty else { return false }
        let kind: IsiXViewerInput.Kind
        switch event.type {
        case .leftMouseDown: kind = .mouseDown
        case .leftMouseDragged: kind = .mouseDragged
        case .leftMouseUp: kind = .mouseUp
        case .keyDown: kind = .keyDown
        default: return false
        }
        let interested = runtimes.filter { $0.inputKinds.contains(kind.kinds) }
        guard !interested.isEmpty, view.curDCM != nil, let (viewer, id) = viewer(ofImageView: view) else { return false }
        // A key has no position of its own: the pointer's position is taken.
        let inWindow = kind == .keyDown ? (view.window?.mouseLocationOutsideOfEventStream ?? .zero) : event.locationInWindow
        // The application keeps pixel centres at half coordinates; the plugin API at whole ones.
        let pixel = view.convert(fromNSView2GL: view.convert(inWindow, from: nil))
        let isMouse = kind != .keyDown
        let input = IsiXViewerInput(kind: kind, viewerID: id,
                                    position: IsiXSlicePosition(slice: Int(view.curImage), phase: Int(viewer.curMovieIndex())),
                                    location: IsiXPixelPoint(x: Double(pixel.x) - 0.5, y: Double(pixel.y) - 0.5),
                                    locationInWindow: inWindow, windowNumber: event.windowNumber,
                                    modifierFlags: event.modifierFlags, timestamp: event.timestamp,
                                    clickCount: isMouse ? event.clickCount : 0,
                                    characters: isMouse ? nil : event.characters, keyCode: isMouse ? nil : event.keyCode)
        var taken = false
        for runtime in interested where runtime.handleInput(input) {
            taken = true
        }
        return taken
    }

    /// Lets the plugins draw over the image a view is drawing, in the canvas
    /// the view posted with HorosDrawObjectsCanvasNotification.
    func drawOverlays(_ note: Notification) {
        guard let view = note.object as? DCMView, let (viewer, id) = viewer(ofImageView: view) else { return }
        let drawing = runtimes.filter { $0.hasOverlays(on: id) }
        guard !drawing.isEmpty, let canvas = note.userInfo?["canvas"] as? ROICanvas,
              let context = canvas.modelContext() else { return }
        func number(_ key: String) -> CGFloat { CGFloat((note.userInfo?[key] as? NSNumber)?.doubleValue ?? 0) }
        let scale = number("scaleValue")
        guard scale > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        // The canvas's model coordinates are the ROIs' own: pixels from the
        // image's centre, times the zoom. The centre of the first pixel is at
        // (0.5, 0.5) for the application and at (0, 0) for the plugin API.
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: 0.5 - number("offsetx"), y: 0.5 - number("offsety"))
        let backing = view.window?.backingScaleFactor ?? 1
        let point = context.convertToUserSpace(CGSize(width: backing, height: 0))
        let overlay = IsiXOverlayContext(cgContext: context, viewerID: id,
                                         position: IsiXSlicePosition(slice: Int(view.curImage), phase: Int(viewer.curMovieIndex())),
                                         pointSize: hypot(point.width, point.height))
        for runtime in drawing {
            runtime.drawOverlays(overlay)
        }
    }
}
