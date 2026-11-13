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

// The entry points tools/probe-preference-read.m calls in each revision's image
// of the preferences catalog (tools/measure-object-interleaved.py compiles this
// file with that revision's PreferenceStore.swift and its companions): the
// typed read of two keys, as the application reads its preferences, and the
// same read while a piece of work gives another key a value of its own.

private let probeSwitch = PreferenceKey<Bool>("IsiXPreferenceReadProbeSwitch", registered: "1")
private let probeNumber = PreferenceKey<Int>("IsiXPreferenceReadProbeNumber", registered: "7")
private let probeHeld = PreferenceKey<Bool>("IsiXPreferenceReadProbeHeld", registered: "1")

@_cdecl("preference_read_prepare")
public func preferenceReadPrepare() {
    UserDefaults.standard.register(defaults: [probeSwitch.name: "1", probeNumber.name: "7", probeHeld.name: "1"])
}

/// Reads the two keys `count` times and answers what it read, so that the
/// reads are not removed.
@_cdecl("preference_read_batch")
public func preferenceReadBatch(_ count: Int) -> Int {
    let defaults = UserDefaults.standard
    var sum = 0
    for _ in 0..<count {
        if defaults[probeSwitch] { sum &+= 1 }
        sum &+= defaults[probeNumber]
    }
    return sum
}

/// Work gives the third key a value, as the opening of a study does.
@_cdecl("preference_read_hold")
public func preferenceReadHold() {
    TemporaryPreference(probeHeld).set(false)
}

@_cdecl("preference_read_release")
public func preferenceReadRelease() {
    TemporaryPreference(probeHeld).restore()
}
