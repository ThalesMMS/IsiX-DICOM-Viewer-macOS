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

/// The window that was key before a transient panel took the keyboard, which
/// gets it back when the panel goes.
///
/// A wait panel makes itself key while it shows. Ordered out, it leaves the
/// application without a key window: AppKit hands the keyboard back only at
/// the end of a modal session, and a panel that never opened one leaves the
/// choice of the next key window to the system, which may bring forward
/// another window of the application than the one the user was working in.
/// The window is made key again before the panel is ordered out, so that
/// there is never a choice to make, and it is not reordered: the other
/// windows keep their places.
@MainActor
struct KeyWindowReturn {
    /// Not retained: a window closed while the panel showed gets nothing back.
    private weak var window: NSWindow?

    /// Notes `key`, the key window, before `panel` becomes key. A panel shown
    /// again while it is key keeps the window noted the first time.
    mutating func remember(_ key: NSWindow?, before panel: NSWindow?) {
        guard let key, key !== panel else { return }
        window = key
    }

    /// Orders `panel` out, runs `afterOrderOut` (the end of its modal
    /// session) and leaves the window noted as the key window, when it is
    /// still on screen. A panel that is no longer key gives nothing back: the
    /// keyboard went elsewhere meanwhile, and stays there.
    mutating func orderOut(_ panel: NSWindow?, afterOrderOut: () -> Void = {}) {
        let previous = window
        window = nil
        let returns = (panel?.isKeyWindow ?? false) && previous != nil && previous !== panel

        if returns { Self.makeKey(previous) }
        panel?.orderOut(nil)
        afterOrderOut()
        if returns { Self.makeKey(previous) }
    }

    private static func makeKey(_ window: NSWindow?) {
        guard let window, window.isVisible, window.canBecomeKey, !window.isKeyWindow else { return }
        window.makeKey()
    }
}
