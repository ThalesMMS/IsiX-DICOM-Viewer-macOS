//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation

/// The tools of the mouse buttons in a volume view (VRView) and in the planes
/// of the 3D MPR and of the curved MPR. A plane is a 2D view: it draws the
/// tools a 2D view draws (the window level of a projection slab, next, its
/// ROIs) and hands the other presses to a hidden volume view, which moves the
/// plane's camera. The values are DCMView.h's ToolMode, as ViewInput.Tool
/// names them.
public enum VolumeViewButtons {

    /// The tool a press works with in a volume view. A plane hands the press
    /// of its right or middle button over with the tool that button has there
    /// (`given`), as the left button's is the view's own tool (`current`).
    /// Without one, as in the volume rendering window, the right button
    /// zooms (unless the contextual menu is up), the buttons but the left one
    /// pan, and the left one has the view's tool. The modifier keys then
    /// choose, whatever the button: Control rotates, Shift zooms, Command
    /// pans, Option windows, Command-Option rotates and Command-Control turns
    /// the camera.
    public static func tool(button: ViewInput.Button, current: Int16, given: Int16?,
                            modifiers: ViewInput.Modifiers, contextualMenuActive: Bool) -> Int16 {
        // The ToolMode values are written out, as in ViewInput.tool: a static
        // let is read through an accessor in an unoptimized build.
        var tool: Int16
        if let given {
            tool = given
        } else {
            switch button {
            case .right where !contextualMenuActive: tool = 2 // zoom
            case .other: tool = 1 // translate
            default: tool = current
            }
        }

        let m = modifiers.rawValue
        let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
        if m & control != 0 { tool = 3 } // rotate
        if m & shift != 0 { tool = 2 } // zoom
        if m & command != 0 { tool = 1 } // translate
        if m & option != 0 { tool = 0 } // windowLevel
        if m & command != 0 && m & option != 0 { tool = 3 } // rotate
        if m & command != 0 && m & control != 0 { tool = 18 } // camera3D
        return tool
    }

    /// The tool a plane of the 3D MPR (or, `curved`, of the curved MPR) gives
    /// its right or middle button: the tool chosen for that button in a 2D
    /// viewer when the plane has it, the move tool when it has not, as the
    /// buttons past the middle one move the image. A plane has the tools of
    /// its toolbar (window level, move, zoom, rotate, next, the camera's 3D
    /// rotation, and the curved path in the curved MPR), the volume view's 3D
    /// rotation and the blended window level its hidden volume view answers,
    /// and the ROIs it draws. It has no patient crosshair, none of the ROIs only
    /// the 2D viewer draws (axis, dynamic angle, TAGT), and none of the tools
    /// that act on the volume itself (3D point, scissors, bone removal): the
    /// hidden volume view would run them on the volume the planes are cut from.
    public static func planeTool(_ tool: Int16, curved: Bool) -> Int16 {
        switch tool {
        case 0, 1, 2, 3, 4, // window level, move, zoom, rotate, next
             7, 18, 22, // 3D rotation, the camera's 3D rotation, blended window level
             5, 6, 9, 10, 11, 12, 13, 14, 15, 19, 20, 23, 24, 25: // the ROIs a plane draws
            return tool
        case 28 where curved: // the curved path
            return tool
        default:
            return 1 // translate
        }
    }
}
