//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Testing
@testable import IsiXImaging

@Suite struct MPRZoomSyncTests {

    @Test func propagatesWhenTurnedOnAndWhenAPinchEnds() {
        #expect(MPRZoomSync.propagates(at: .settingChanged, isOn: true))
        #expect(MPRZoomSync.propagates(at: .pinchEnded, isOn: true))
    }

    @Test func waitsForTheEndOfThePinch() {
        #expect(!MPRZoomSync.propagates(at: .pinchChanged, isOn: true))
    }

    @Test func propagatesNothingWhileOff() {
        #expect(!MPRZoomSync.propagates(at: .settingChanged, isOn: false))
        #expect(!MPRZoomSync.propagates(at: .pinchChanged, isOn: false))
        #expect(!MPRZoomSync.propagates(at: .pinchEnded, isOn: false))
    }

    @Test func theOtherPlanesFollowTheSource() {
        #expect(MPRZoomSync.followers(of: 0, scales: [80, 120, 150]) == [1, 2])
        #expect(MPRZoomSync.followers(of: 1, scales: [80, 120, 150]) == [0, 2])
        #expect(MPRZoomSync.followers(of: 2, scales: [80, 120, 150]) == [0, 1])
    }

    @Test func aPlaneAlreadyAtTheScaleIsLeftAlone() {
        #expect(MPRZoomSync.followers(of: 0, scales: [80, 80, 150]) == [2])
        #expect(MPRZoomSync.followers(of: 1, scales: [80, 80, 80]).isEmpty)
    }

    @Test func aPlaneWithoutACameraDoesNotFollow() {
        #expect(MPRZoomSync.followers(of: 0, scales: [80, nil, 150]) == [2])
    }

    @Test func aSourceWithoutAUsableScaleLeadsNoPlane() {
        #expect(MPRZoomSync.followers(of: 0, scales: [nil, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: 0, scales: [0, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: 0, scales: [-3, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: 0, scales: [.nan, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: 0, scales: [.infinity, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: 3, scales: [80, 120, 150]).isEmpty)
        #expect(MPRZoomSync.followers(of: -1, scales: [80, 120, 150]).isEmpty)
    }
}
