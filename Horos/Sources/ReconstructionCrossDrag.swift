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

/// A drag of the cross's centre in a plane of the 3D MPR or of the curved MPR.
///
/// The centre is caught within a box of a few points around it. The press
/// used to put the centre under the pointer at once, so a click that did not
/// move shifted the cross by where in the box it fell, the planes with it, and
/// left their cameras to undo. The cross now keeps the distance to the
/// pointer it had at the press: a still click moves nothing, and a drag moves
/// the cross by what the pointer moved, without a jump at its start.
@MainActor
enum ReconstructionCrossDrag {

    /// From the pointer to the cross's centre at a press, in the view's points.
    /// `centre` is the centre as the plane holds it, in millimetres of its image.
    static func offset(ofCentre centre: NSPoint, from event: NSEvent, in view: DCMView) -> NSPoint {
        let spacingX = view.curDCM?.pixelSpacingX ?? 0, spacingY = view.curDCM?.pixelSpacingY ?? 0
        guard spacingX > 0, spacingY > 0 else { return .zero }
        let inView = view.convert(fromGL2NSView: NSPoint(x: centre.x / CGFloat(spacingX), y: centre.y / CGFloat(spacingY)))
        let pressed = view.convert(event.locationInWindow, from: nil)
        return NSPoint(x: inView.x - pressed.x, y: inView.y - pressed.y)
    }

    /// Where a drag puts the cross's centre, in the view's points: the pointer
    /// and the distance the press found.
    static func centre(at event: NSEvent, offset: NSPoint, in view: NSView) -> NSPoint {
        let pointer = view.convert(event.locationInWindow, from: nil)
        return NSPoint(x: pointer.x + offset.x, y: pointer.y + offset.y)
    }

    /// Whether a node at `node` would lie within half a screen point of
    /// `neighbour`, `pointLength` being a point's length in the path's space: a
    /// click on a node that does not catch it must not leave a second node on it.
    static func isOnTop(_ node: N3Vector, of neighbour: N3Vector?, pointLength: CGFloat) -> Bool {
        guard let neighbour else { return false }
        return N3VectorDistance(node, neighbour) < pointLength / 2
    }
}
