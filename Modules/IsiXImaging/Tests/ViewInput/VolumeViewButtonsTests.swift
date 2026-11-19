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
import Testing
@testable import IsiXImaging

@Suite struct VolumeViewButtonsTests {

    typealias T = ViewInput.Tool

    func tool(_ button: ViewInput.Button, current: Int16 = T.windowLevel, given: Int16? = nil,
              _ modifiers: ViewInput.Modifiers = [], menu: Bool = false) -> Int16 {
        VolumeViewButtons.tool(button: button, current: current, given: given, modifiers: modifiers,
                               contextualMenuActive: menu)
    }

    // The volume rendering window hands no tool over: its buttons keep the
    // rule they had.
    @Test func withoutAGivenToolTheButtonDecides() {
        #expect(tool(.left, current: T.rotate3D) == T.rotate3D)
        #expect(tool(.right, current: T.rotate3D) == T.zoom)
        #expect(tool(.right, current: T.rotate3D, menu: true) == T.rotate3D)
        #expect(tool(.other(buttonNumber: 2), current: T.rotate3D) == T.translate)
        #expect(tool(.other(buttonNumber: 3), current: T.rotate3D) == T.translate)
    }

    // A plane's right and middle buttons keep the tool they were given: zoom
    // stays zoom and rotate stays rotate, where the volume view made the right
    // button zoom and the middle one pan.
    @Test func aGivenToolIsKept() {
        for button: ViewInput.Button in [.right, .other(buttonNumber: 2), .left] {
            for given in [T.windowLevel, T.translate, T.zoom, T.rotate, T.camera3D] {
                #expect(tool(button, current: T.windowLevel, given: given) == given)
            }
        }
        #expect(tool(.right, given: T.rotate, menu: true) == T.rotate)
    }

    // The modifier keys override the given tool as they override the left
    // button's, in the volume view's order.
    @Test func modifiersOverrideAGivenTool() {
        let right = ViewInput.Button.right
        #expect(tool(right, given: T.zoom, .control) == T.rotate)
        #expect(tool(right, given: T.rotate, .shift) == T.zoom)
        #expect(tool(right, given: T.zoom, .command) == T.translate)
        #expect(tool(right, given: T.zoom, .option) == T.windowLevel)
        #expect(tool(right, given: T.zoom, [.command, .option]) == T.rotate)
        #expect(tool(right, given: T.zoom, [.command, .control]) == T.camera3D)
        #expect(tool(right, given: T.zoom, [.shift, .option]) == T.windowLevel)
        #expect(tool(right, given: T.rotate, .capsLock) == T.rotate)
        // Without a given tool, the same keys over the button's own.
        #expect(tool(.other(buttonNumber: 2), .shift) == T.zoom)
        #expect(tool(.left, current: T.next, [.command, .control]) == T.camera3D)
    }

    // What a 2D viewer can choose for the right or middle button and a plane
    // has stays; the rest moves the plane, as the buttons past the middle do.
    @Test func aPlaneMovesWithWhatItLacks() {
        for kept in [T.windowLevel, T.translate, T.zoom, T.rotate, T.next, T.rotate3D, T.camera3D, T.windowLevelBlended,
                     5, 6, 9, 10, 11, 12, T.text, 14, 15, 19, 20, T.repulsor, 24, T.roiSelector] {
            #expect(VolumeViewButtons.planeTool(kept, curved: false) == kept)
            #expect(VolumeViewButtons.planeTool(kept, curved: true) == kept)
        }
        // The patient crosshair, the volume's own tools, the ROIs only the 2D
        // viewer draws, and values no tool has.
        for lacking: Int16 in [T.cross, 16, 17, 21, 26, 27, 29, 30, -1, 300] {
            #expect(VolumeViewButtons.planeTool(lacking, curved: false) == T.translate)
            #expect(VolumeViewButtons.planeTool(lacking, curved: true) == T.translate)
        }
        // The curved path is the curved MPR's.
        #expect(VolumeViewButtons.planeTool(28, curved: true) == 28)
        #expect(VolumeViewButtons.planeTool(28, curved: false) == T.translate)
    }
}
