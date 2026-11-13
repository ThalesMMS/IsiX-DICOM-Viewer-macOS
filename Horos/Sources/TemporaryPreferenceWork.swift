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
import IsiXPreferences

/// Work that needs a preference at a value of its own while it runs: the
/// opening of a study has the windows tiled, the loading of a series keeps
/// its settings from the other viewers, the tiling of the windows too.
///
/// The value is for this process and for as long as the work lasts
/// (IsiXPreferences' TemporaryPreferenceHolds, which says what becomes of work
/// inside work and of a choice the person makes meanwhile). Nothing is stored:
/// the preference used to be written and then written back with the value
/// read, which stored a value that was only the registered one, stored the
/// value of the launch over the person's, and left the value of the work as
/// the person's choice when the application ended in the middle.
///
/// On the main thread, where the viewers' windows are opened and arranged.
@MainActor
enum TemporaryPreferenceWork {
    /// Runs `work` with `key` at `value`, and takes the value back when the
    /// work returns or raises: an exception goes on to the caller once it is
    /// taken back. With `silently`, the application is not told that
    /// preferences changed (AppController.checkForPreferencesUpdate) by the
    /// value given and by its end, as the tiling of the windows asks.
    static func during<Value: PreferenceValue>(_ key: PreferenceKey<Value>, at value: Value, silently: Bool = false, _ work: () -> Void) {
        let holds = TemporaryPreferenceHolds.standard
        if silently { AppController.checkForPreferencesUpdate(false) }
        let hold = holds.hold(key, at: value)
        if silently { AppController.checkForPreferencesUpdate(true) }

        let raised = HorosObjCException.caught(work)

        if silently { AppController.checkForPreferencesUpdate(false) }
        holds.release(hold)
        if silently { AppController.checkForPreferencesUpdate(true) }
        raised?.raise()
    }
}
