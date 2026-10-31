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
import IsiXPreferences
@testable import IsiXImaging

@Suite struct ViewerInputSettingsTests {

    // MARK: - Tools by button

    @Test func eachButtonUsesItsTool() {
        // The factory tools: window level left, zoom right, move middle.
        let factory = ViewerToolBindings(left: 0, right: 2, middle: 1)
        let none = ViewInput.Modifiers(rawValue: 0)
        #expect(factory.tool(button: .left, modifiers: none, leftDrawsROIs: false, hasBlending: false) == 0)
        #expect(factory.tool(button: .right, modifiers: none, leftDrawsROIs: false, hasBlending: false) == 2)
        #expect(factory.tool(button: .other(buttonNumber: 2), modifiers: none, leftDrawsROIs: false, hasBlending: false) == 1)
        // The middle tool chosen in the toolbar; other buttons still move the image.
        let chosen = ViewerToolBindings(left: 5, right: 4, middle: 3)
        #expect(chosen.tool(button: .other(buttonNumber: 2), modifiers: none, leftDrawsROIs: true, hasBlending: false) == 3)
        #expect(chosen.tool(button: .other(buttonNumber: 3), modifiers: none, leftDrawsROIs: true, hasBlending: false) == 1)
    }

    @Test func bindingsAnswerAsTheRuleOverTheButtonsTools() {
        // Equivalence with the view's former call: the rule with the middle tool
        // only for the middle button.
        let modifierSets: [UInt] = [0, 1 << 17, 1 << 18, 1 << 19, 1 << 20, (1 << 19) | (1 << 20), (1 << 18) | (1 << 19), (1 << 17) | (1 << 19)]
        let buttons: [ViewInput.Button] = [.left, .right, .other(buttonNumber: 2), .other(buttonNumber: 4)]
        for left in [Int16(0), 5, 6, 25] {
            let bindings = ViewerToolBindings(left: Int(left), right: 9, middle: 13)
            for raw in modifierSets {
                for button in buttons {
                    for drawsROIs in [false, true] {
                        for blending in [false, true] {
                            let modifiers = ViewInput.Modifiers(rawValue: raw)
                            var middle = ViewInput.Tool.translate
                            if case .other(let n) = button, n == 2 { middle = 13 }
                            let former = ViewInput.tool(button: button, left: left, right: 9, middle: middle, modifiers: modifiers,
                                                        leftDrawsROIs: drawsROIs, hasBlending: blending)
                            #expect(bindings.tool(button: button, modifiers: modifiers, leftDrawsROIs: drawsROIs, hasBlending: blending) == former)
                        }
                    }
                }
            }
        }
    }

    @Test func storedToolsKeepSixteenBits() {
        let bindings = ViewerToolBindings(left: 65541, right: -1, middle: 19)
        #expect(bindings.left == 5)
        #expect(bindings.right == -1)
        #expect(bindings.middle == 19)
    }

    // MARK: - Hot keys

    /// The factory HOTKEYS dictionary, as the preference registers it.
    private func storedFactoryHotKeys() -> [String: Any]? {
        let environment = PreferenceEnvironment(viewer: true, appStore: false, hostName: nil, graphicsMemory: 0)
        return ViewerPreferences.hotKeys.registration?.value(in: environment) as? [String: Any]
    }

    @Test func factoryHotKeys() {
        let map = HotKeyMap(stored: storedFactoryHotKeys())
        #expect(!map.actions.isEmpty)
        #expect(map.command(forTyped: "~") == .defaultWindowLevel)
        #expect(map.command(forTyped: "0") == .fullDynamic)
        #expect(map.command(forTyped: "1") == .windowLevelPreset(0))
        #expect(map.command(forTyped: "9") == .windowLevelPreset(8))
        #expect(map.command(forTyped: "dbl-click") == .fullScreen)
        #expect(map.command(forTyped: "dbl-click + alt") == .sync3DPosition)
        #expect(map.command(forTyped: "dbl-click + cmd") == .setKeyImage)
        // Every factory action is a command of a 2D view or one it leaves alone.
        for action in map.actions.values {
            if let command = ViewerKeyCommand.HotKey(action: action) {
                #expect(command != .tool(action: 29))
            } else {
                #expect([29, 30, 31, 32].contains(action))
            }
        }
    }

    @Test func aHotKeyOfTheUser() {
        var stored = storedFactoryHotKeys() ?? [:]
        stored["q"] = NSNumber(value: 18)       // LengthHotKeyAction
        stored["k"] = "52" as NSString          // SetKeyImageAction, stored as text
        stored["r"] = NSNumber(value: 54)       // ResliceCoronalHotKeyAction
        stored["s"] = NSNumber(value: 36)       // UnreadHotKeyAction
        stored["o"] = NSNumber(value: 43)       // Preset3OpacityHotKeyAction
        let map = HotKeyMap(stored: stored)
        #expect(map.action(forTyped: "Q") == 18)
        #expect(map.command(forTyped: "Q") == .tool(action: 18))
        #expect(map.command(forTyped: "k") == .setKeyImage)
        #expect(map.command(forTyped: "r") == .reslice(1))
        #expect(map.command(forTyped: "s") == .status(1))
        #expect(map.command(forTyped: "o") == .opacityPreset(3))
        #expect(map.command(forTyped: "unknown key") == nil)
    }

    @Test func eachActionOfTheHeader() {
        #expect(ViewerKeyCommand.HotKey(action: 0) == .defaultWindowLevel)
        #expect(ViewerKeyCommand.HotKey(action: 11) == .flipVertical)
        #expect(ViewerKeyCommand.HotKey(action: 12) == .flipHorizontal)
        for action: Int32 in Array(13...28) + [33, 34, 40] {
            #expect(ViewerKeyCommand.HotKey(action: action) == .tool(action: action))
        }
        for action: Int32 in 29...32 { #expect(ViewerKeyCommand.HotKey(action: action) == nil) }
        #expect(ViewerKeyCommand.HotKey(action: 35) == .status(0))
        #expect(ViewerKeyCommand.HotKey(action: 39) == .status(4))
        #expect(ViewerKeyCommand.HotKey(action: 41) == .opacityPreset(1))
        #expect(ViewerKeyCommand.HotKey(action: 49) == .opacityPreset(9))
        #expect(ViewerKeyCommand.HotKey(action: 53) == .reslice(0))
        #expect(ViewerKeyCommand.HotKey(action: 55) == .reslice(2))
        #expect(ViewerKeyCommand.HotKey(action: 56) == nil)
        #expect(ViewerKeyCommand.HotKey(action: -1) == nil)
    }

    @Test func opacityPresets() {
        // The view applied the preset when the stored tables were at least
        // its number less one: preset 1 is the linear table.
        #expect(ViewerKeyCommand.opacityChoice(preset: 1, storedTableCount: 0) == .linear)
        #expect(ViewerKeyCommand.opacityChoice(preset: 2, storedTableCount: 0) == nil)
        #expect(ViewerKeyCommand.opacityChoice(preset: 2, storedTableCount: 1) == .stored(index: 0))
        #expect(ViewerKeyCommand.opacityChoice(preset: 9, storedTableCount: 8) == .stored(index: 7))
        #expect(ViewerKeyCommand.opacityChoice(preset: 9, storedTableCount: 7) == nil)
    }

    // MARK: - The pixel under the pointer

    @Test func pixelUnderThePointerAsTheViewReadIt() {
        let probe = PixelProbe(width: 4, height: 3)
        // The former reading: on the image from 0 to below the size, the
        // location kept as a Float and truncated to 32 bits.
        func former(_ x: CGFloat, _ y: CGFloat) -> (Int, Int)? {
            guard x >= 0 && x < 4, y >= 0 && y < 3 else { return nil }
            let mouseX = Float(x), mouseY = Float(y)
            return (Int(Int32(mouseX)), Int(Int32(mouseY)))
        }
        for x: CGFloat in [-0.5, 0, 0.4, 1.99, 3.5, 3.999999, 4, 7] {
            for y: CGFloat in [-1, 0, 2.5, 2.9999999, 3] {
                let got = probe.pixel(at: CGPoint(x: x, y: y))
                let expected = former(x, y)
                #expect(got?.x == expected?.0 && got?.y == expected?.1)
            }
        }
    }

    @Test func colourOfAnARGBPixel() {
        let probe = PixelProbe(width: 2, height: 2)
        let argb: [UInt8] = [255, 10, 20, 30, 255, 11, 21, 31,
                             255, 12, 22, 32, 255, 13, 23, 33]
        #expect(probe.rgbOffsets(x: 1, y: 1) == (13, 14, 15))
        argb.withUnsafeBufferPointer { buffer in
            let rgb = probe.rgb(x: 0, y: 1, in: buffer.baseAddress!)
            #expect(rgb == (12, 22, 32))
        }
    }

    // MARK: - The magnifier

    @Test func magnifierSettings() {
        let none = MagnifierSettings(storedZoomFactor: nil, storedSizeFactor: nil)
        #expect(none.zoomFactor == 3 && none.sizeFactor == 1 && !none.inCorner && !none.whileMeasuring)
        let clamped = MagnifierSettings(storedZoomFactor: NSNumber(value: 9), storedSizeFactor: "x", inCorner: true, whileMeasuring: true)
        #expect(clamped.zoomFactor == 4 && clamped.sizeFactor == 1 && clamped.inCorner && clamped.whileMeasuring)
        #expect(MagnifierSettings(storedZoomFactor: NSNumber(value: Float.nan), storedSizeFactor: NSNumber(value: 0.1)).zoomFactor == 3)
        #expect(MagnifierSettings(storedZoomFactor: nil, storedSizeFactor: NSNumber(value: 0.1)).sizeFactor == 0.5)
        var zoom: Float = 3
        for _ in 0..<20 { zoom = MagnifierSettings.zoomFactor(zoom, steppedIn: true) }
        #expect(zoom == 2.2)
        #expect(MagnifierSettings.zoomFactor(4, steppedIn: false) == 4)
        #expect(MagnifierSettings.sizeFactor(1, steppedUp: true) == 1.25)
        #expect(MagnifierSettings.sizeFactor(3, steppedUp: true) == 3)
        let stepped = none.stepped(zoomCloser: false, sizeLarger: true)
        #expect(stepped.zoomFactor == MagnifierSettings.zoomFactor(3, steppedIn: false) && stepped.sizeFactor == 1.25)
    }
}
