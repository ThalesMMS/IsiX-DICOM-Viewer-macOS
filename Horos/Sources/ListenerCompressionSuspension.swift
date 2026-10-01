//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import Synchronization

/// Turns the ListenerCompressionSettings default to 0 (files are imported as
/// they arrive, without compressing or decompressing them) while retrievals
/// that need their images at once are running, and gives it back its value
/// when the last of them ends.
///
/// Each retrieval used to save the value, set 0 and put the saved value back
/// by itself. Two at a time (the comparative retrievals run on up to five
/// threads, beside the ones the browser makes when it opens a study) could
/// then save the 0 set by the other, and leave it for good. Here only the
/// first to begin saves the value, and only the last to end restores it.
// @unchecked Sendable: the retrieval threads share `shared`. `defaults` is a
// constant UserDefaults, which is thread-safe but not marked Sendable; the
// count and the saved value are in `state`.
final class ListenerCompressionSuspension: @unchecked Sendable {
    static let shared = ListenerCompressionSuspension(defaults: .standard)

    static let key = "ListenerCompressionSettings"

    private let defaults: UserDefaults
    /// How many retrievals hold the suspension, and the value to put back.
    private let state = Mutex<(holders: Int, saved: Int)>((0, 0))

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Sets the default to 0, saving its value if no other retrieval holds it.
    func begin() {
        state.withLock { state in
            if state.holders == 0 {
                state.saved = defaults.integer(forKey: Self.key)
                defaults.set(0, forKey: Self.key) //No time for decompression....
            }
            state.holders += 1
        }
    }

    /// Ends a `begin()`; the last one to end puts the saved value back.
    func end() {
        state.withLock { state in
            guard state.holders > 0 else { return }
            state.holders -= 1
            if state.holders == 0 {
                defaults.set(state.saved, forKey: Self.key)
            }
        }
    }
}
