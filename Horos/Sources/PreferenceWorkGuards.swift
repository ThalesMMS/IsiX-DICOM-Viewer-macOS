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
import IsiXPreferences

// Work of the application that overrides a preference while it lasts calls
// code that can raise an NSException (AppKit, Core Data, the VTK adapters),
// which leaves a Swift frame without running what it deferred. These run the
// work as an @try block, so that what it asked of the preference ends however
// it ends, and the exception goes on to the caller afterwards.

extension ForcedPreference {
    /// Runs `work` as a piece of work that holds this, ended also when it
    /// raises an exception. Any thread.
    func whileWorking(_ work: () -> Void) {
        begin()
        let raised = HorosObjCException.caught(work)
        end()
        raised?.raise()
    }
}

extension TemporaryPreference {
    /// Runs `work` while every reader of the key in this process reads
    /// `value`, taken back also when it raises an exception. On the main
    /// thread, as the argument domain is exchanged and the observers of the
    /// key are told there.
    @MainActor
    func whileWorking(with value: Value, _ work: () -> Void) {
        set(value)
        let raised = HorosObjCException.caught(work)
        restore()
        raised?.raise()
    }
}

extension StoredPreference {
    /// Runs `work`, then puts back what was stored under the key before it,
    /// if other code stored something else meanwhile, also when the work
    /// raises an exception.
    func whileWorking(_ work: () -> Void) {
        let raised = HorosObjCException.caught(work)
        putBack()
        raised?.raise()
    }
}
