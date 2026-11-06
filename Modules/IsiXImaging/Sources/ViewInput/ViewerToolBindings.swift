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

/// The tools of the mouse buttons of a 2D view: the left, right and middle
/// buttons' tools, the ToolMode values of DCMView.h, as the preferences
/// DEFAULTLEFTTOOL, DEFAULTRIGHTTOOL and DEFAULTMIDDLETOOL keep them. The
/// app reads and writes those preferences through their typed keys; the tool
/// an event works with is ViewInput's rule over these bindings.
public struct ViewerToolBindings: Sendable, Equatable {
    public var left: Int16
    public var right: Int16
    public var middle: Int16

    /// The tools of the stored numbers, each kept to the 16 bits of a ToolMode.
    public init(left: Int, right: Int, middle: Int) {
        self.left = Int16(truncatingIfNeeded: left)
        self.right = Int16(truncatingIfNeeded: right)
        self.middle = Int16(truncatingIfNeeded: middle)
    }

    /// The tool `button` works with under `modifiers`: the button's own tool,
    /// any other button but the middle one moving the image, the modifiers
    /// overriding it afterwards (ViewInput.tool). The middle tool counts only
    /// for the middle button.
    public func tool(button: ViewInput.Button, modifiers: ViewInput.Modifiers, leftDrawsROIs: Bool, hasBlending: Bool) -> Int16 {
        let middle: Int16
        if case .other(let number) = button, number == 2 { middle = self.middle } else { middle = ViewInput.Tool.translate }
        return ViewInput.tool(button: button, left: left, right: right, middle: middle, modifiers: modifiers,
                              leftDrawsROIs: leftDrawsROIs, hasBlending: hasBlending)
    }
}
