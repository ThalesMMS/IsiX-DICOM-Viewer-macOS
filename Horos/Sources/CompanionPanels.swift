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

/// The panels a window puts on the screen beside itself: the shading values
/// of a 3D window, the information of a 3D point.
///
/// Such a panel is a window of the nib of its own, and its controls send
/// their actions to the nib's owner, which they do not keep. AppKit keeps a
/// window for as long as it is on the screen, so a panel left open when its
/// window closed stayed there after the window's controller was gone, with
/// buttons that would message it. The window that closes takes its panels off
/// the screen while its controller is still there; they are then released
/// with the other objects of the nib.
@MainActor
enum CompanionPanels {
    /// Takes `panels` off the screen, a sheet of theirs included.
    ///
    /// A panel is ordered out, not closed: nothing is told that a window will
    /// close, as a controller that hears it of a window of its nib would take
    /// for its own, and a panel the nib made to be released when closed is not
    /// released before the nib's owner lets go of it.
    static func takeOffScreen(_ panels: NSWindow?...) {
        for case let panel? in panels {
            if let sheet = panel.attachedSheet { panel.endSheet(sheet) }
            panel.orderOut(nil)
        }
    }
}
