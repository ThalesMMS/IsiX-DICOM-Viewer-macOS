//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

// What a plugin does on a viewer's image beyond its data: drawing over it with
// Core Graphics, and taking the mouse and key events of the image, as a ROI
// tool does.

import AppKit

/// A mouse or key event on a viewer's image.
public struct IsiXViewerInput: Sendable {
    public enum Kind: Hashable, Sendable {
        /// The left button went down: a click, or the start of a drag.
        case mouseDown
        /// The pointer moved with the left button down.
        case mouseDragged
        /// The left button went up.
        case mouseUp
        /// A key went down while the image had the keyboard.
        case keyDown

        /// The kind as a set, for `IsiXInputKinds`.
        public var kinds: IsiXInputKinds {
            switch self {
            case .mouseDown: return .mouseDown
            case .mouseDragged: return .mouseDragged
            case .mouseUp: return .mouseUp
            case .keyDown: return .keyDown
            }
        }
    }

    public let kind: Kind
    public let viewerID: IsiXViewerID
    /// The image shown when the event happened.
    public let position: IsiXSlicePosition
    /// Where the pointer was on that image, in pixel coordinates (the centre
    /// of the first pixel at (0, 0)); for a key, where it was last.
    public let location: IsiXPixelPoint
    /// Where the pointer was in the viewer's window, in the window's
    /// coordinates, and the window's number: what an `NSEvent` of the event
    /// would carry.
    public let locationInWindow: CGPoint
    public let windowNumber: Int
    public let modifierFlags: NSEvent.ModifierFlags
    public let timestamp: TimeInterval
    /// 1 for a single click, 2 for a double click; 0 for a key.
    public let clickCount: Int
    /// For a key: its characters and key code.
    public let characters: String?
    public let keyCode: UInt16?

    public init(kind: Kind, viewerID: IsiXViewerID, position: IsiXSlicePosition, location: IsiXPixelPoint,
                locationInWindow: CGPoint = .zero, windowNumber: Int = 0, modifierFlags: NSEvent.ModifierFlags = [],
                timestamp: TimeInterval = 0, clickCount: Int = 0, characters: String? = nil, keyCode: UInt16? = nil) {
        self.kind = kind
        self.viewerID = viewerID
        self.position = position
        self.location = location
        self.locationInWindow = locationInWindow
        self.windowNumber = windowNumber
        self.modifierFlags = modifierFlags
        self.timestamp = timestamp
        self.clickCount = clickCount
        self.characters = characters
        self.keyCode = keyCode
    }
}

public struct IsiXInputKinds: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let mouseDown = IsiXInputKinds(rawValue: 1 << 0)
    public static let mouseDragged = IsiXInputKinds(rawValue: 1 << 1)
    public static let mouseUp = IsiXInputKinds(rawValue: 1 << 2)
    public static let keyDown = IsiXInputKinds(rawValue: 1 << 3)
    public static let all: IsiXInputKinds = [.mouseDown, .mouseDragged, .mouseUp, .keyDown]
}

/// Where an overlay draws: a Core Graphics context over one viewer's image,
/// for the duration of the drawing call only.
///
/// The context's user space is the image's pixel coordinates: one unit per
/// pixel, x along the columns, y down along the rows, the centre of the first
/// pixel at (0, 0), as `IsiXPixelPoint` places it. The viewer's zoom, panning,
/// rotation and flips are already applied. What is drawn lies over the image
/// and the ROIs, beneath the viewer's text.
public struct IsiXOverlayContext {
    public let cgContext: CGContext
    public let viewerID: IsiXViewerID
    /// The image being drawn.
    public let position: IsiXSlicePosition
    /// The length of one point of the screen, in image pixels: a line of
    /// `2 * pointSize` is two points wide whatever the zoom.
    public let pointSize: CGFloat

    @_spi(IsiXHost)
    public init(cgContext: CGContext, viewerID: IsiXViewerID, position: IsiXSlicePosition, pointSize: CGFloat) {
        self.cgContext = cgContext
        self.viewerID = viewerID
        self.position = position
        self.pointSize = pointSize
    }
}

extension IsiXViewer {
    /// Draws over the viewer's image each time the viewer draws it, until the
    /// returned token is invalidated or released, the viewer closes, or the
    /// plugin is deactivated. `draw` runs on the main actor while the viewer
    /// draws: keep it short, and call `setNeedsDisplay()` when what it draws
    /// changes.
    public func addOverlay(_ draw: @escaping @MainActor (IsiXOverlayContext) -> Void) throws -> IsiXObservation {
        try require(.viewerRead)
        guard let registry else {
            throw IsiXPluginError.hostFailure("This viewer handle was not given to a plugin; it cannot draw over the image.")
        }
        guard let key = registry.addOverlay(on: id, draw) else { throw IsiXPluginError.pluginInactive }
        setNeedsDisplay()
        return IsiXObservation(registry: registry, key: key)
    }
}

extension IsiXPluginContext {
    /// Calls `handler` on the main actor with the mouse and key events of
    /// `kinds` on the images of the open 2D viewers, before the viewer acts on
    /// them. When `handler` returns true the viewer does nothing else with the
    /// event: the plugin took it, as a ROI tool takes the clicks it places a
    /// point with. Every handler is asked. Delivered until the returned token
    /// is invalidated or released, or the plugin is deactivated. Needs
    /// `viewer.read`.
    public func interceptInput(_ kinds: IsiXInputKinds = .all,
                               _ handler: @escaping @MainActor (IsiXViewerInput) -> Bool) throws -> IsiXObservation {
        try requireActive()
        try requireCapability(.viewerRead)
        guard let key = observations.addInput(kinds, handler) else { throw IsiXPluginError.pluginInactive }
        return IsiXObservation(registry: observations, key: key)
    }

    var inputKinds: IsiXInputKinds {
        guard isActive, info.capabilities.contains(.viewerRead) else { return [] }
        return observations.inputKinds
    }

    func handleInput(_ input: IsiXViewerInput) -> Bool {
        guard isActive, info.capabilities.contains(.viewerRead) else { return false }
        return observations.deliver(input)
    }

    func hasOverlays(on viewer: IsiXViewerID) -> Bool {
        isActive && observations.hasOverlays(on: viewer)
    }

    func drawOverlays(_ overlay: IsiXOverlayContext) {
        guard isActive, info.capabilities.contains(.viewerRead) else { return }
        observations.draw(overlay)
    }
}
