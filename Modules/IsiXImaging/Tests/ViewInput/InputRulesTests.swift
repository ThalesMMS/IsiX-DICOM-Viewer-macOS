//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import CoreGraphics
import Foundation
import Testing
@testable import IsiXImaging

// The expected values and bits are those the Objective-C of the viewer's input
// gave, compiled by clang for arm64 (at -O0 and -Os alike).
@Suite struct InputRulesTests {

    typealias T = ViewInput.Tool
    let roiTool: Int16 = 5

    @Test func buttonPicksTheTool() {
        #expect(ViewInput.tool(button: .left, left: 6, right: 2, middle: 1, modifiers: [], leftDrawsROIs: true, hasBlending: false) == 6)
        #expect(ViewInput.tool(button: .right, left: 6, right: 2, middle: 1, modifiers: [], leftDrawsROIs: true, hasBlending: false) == 2)
        #expect(ViewInput.tool(button: .other(buttonNumber: 2), left: 6, right: 2, middle: 9, modifiers: [], leftDrawsROIs: true, hasBlending: false) == 9)
        // Back and forward move the image, whatever the middle tool.
        #expect(ViewInput.tool(button: .other(buttonNumber: 3), left: 6, right: 2, middle: 9, modifiers: [], leftDrawsROIs: true, hasBlending: false) == T.translate)
    }

    @Test func modifiersOverrideTheTool() {
        func tool(_ m: ViewInput.Modifiers, roi: Bool = false, left: Int16 = T.next, blending: Bool = false) -> Int16 {
            ViewInput.tool(button: .left, left: left, right: 2, middle: 1, modifiers: m, leftDrawsROIs: roi, hasBlending: blending)
        }
        #expect(tool(.command) == T.translate)
        #expect(tool(.option) == T.windowLevel)
        #expect(tool([.option, .shift]) == T.zoom)
        #expect(tool([.control, .option]) == T.windowLevel)
        #expect(tool([.control, .option], blending: true) == T.windowLevelBlended)
        #expect(tool([.command, .option]) == T.rotate)
        #expect(tool(.shift) == T.zoom)
        #expect(tool(.control) == T.next)
        // A ROI tool keeps Shift for the lens; Command-Option still rotates.
        #expect(tool(.shift, roi: true, left: roiTool) == roiTool)
        #expect(tool([.command, .option], roi: true, left: roiTool) == T.rotate)
        #expect(tool(.shift, left: T.roiSelector) == T.roiSelector)
        #expect(tool([.command, .shift], roi: true, left: roiTool) == T.translate)
        #expect(tool(.capsLock) == T.next)
    }

    @Test func firstMouseWaitsForTheApplicationWithAROITool() {
        #expect(ViewInput.acceptsFirstMouse(tool: 4, applicationIsActive: false))
        #expect(!ViewInput.acceptsFirstMouse(tool: 5, applicationIsActive: false))
        #expect(ViewInput.acceptsFirstMouse(tool: 25, applicationIsActive: true))
    }

    @Test func eachToolHasItsCursor() {
        #expect(ViewInput.cursor(for: T.translate, drawsROIs: true) == .cross)
        #expect(ViewInput.cursor(for: T.translate, drawsROIs: false) == .openHand)
        #expect(ViewInput.cursor(for: T.rotate, drawsROIs: false) == .rotate)
        #expect(ViewInput.cursor(for: T.zoom, drawsROIs: false) == .zoom)
        #expect(ViewInput.cursor(for: T.windowLevel, drawsROIs: false) == .contrast)
        #expect(ViewInput.cursor(for: T.next, drawsROIs: false) == .stack)
        #expect(ViewInput.cursor(for: T.text, drawsROIs: false) == .iBeam)
        #expect(ViewInput.cursor(for: T.rotate3D, drawsROIs: false) == .crosshair)
        #expect(ViewInput.cursor(for: T.cross, drawsROIs: false) == .crosshair)
        #expect(ViewInput.cursor(for: T.repulsor, drawsROIs: false) == .crosshair)
        #expect(ViewInput.cursor(for: T.roiSelector, drawsROIs: false) == .crosshair)
        #expect(ViewInput.cursor(for: T.camera3D, drawsROIs: false) == .rotate3DCamera)
        #expect(ViewInput.cursor(for: T.windowLevelBlended, drawsROIs: false) == .arrow)
    }

    @Test func modifiersTurnOnLabelsLargeDescriptionAndLens() {
        #expect(ViewInput.suppressesLabels([.command, .shift, .option]))
        #expect(!ViewInput.suppressesLabels(.command))
        #expect(ViewInput.showsDescriptionInLarge([.control, .capsLock]))
        #expect(!ViewInput.showsDescriptionInLarge([.control, .option]))
        #expect(ViewInput.isShiftAlone([.shift, .capsLock]))
        #expect(!ViewInput.isShiftAlone([.shift, .control]))
        #expect(ViewInput.syncsPatientPoint([.shift, .control, .option]))
        #expect(!ViewInput.syncsPatientPoint(.shift))
    }

    @Test func doubleClickRotatesByQuarters() {
        #expect(ViewInput.rotationAfterDoubleClick(10, modifiers: []) == 100)
        #expect(ViewInput.rotationAfterDoubleClick(10, modifiers: .shift) == -80)
        #expect(ViewInput.rotationAfterDoubleClick(10, modifiers: [.option, .shift]) == -170)
    }

    @Test func rotationStartIsTheCsBits() {
        let d2r = Double.pi / 180.0
        #expect(ViewInput.rotationStart(12.5, fromCenter: CGPoint(x: 31.25, y: -17.5), xFlipped: false, yFlipped: false, deg2rad: d2r).bitPattern == 0xc2d57f66)
        #expect(ViewInput.rotationStart(12.5, fromCenter: CGPoint(x: 31.25, y: -17.5), xFlipped: true, yFlipped: false, deg2rad: d2r).bitPattern == 0x4303bfb3)
        #expect(ViewInput.rotationStart(-200, fromCenter: CGPoint(x: -3, y: 0.1), xFlipped: true, yFlipped: true, deg2rad: d2r).bitPattern == 0xc2dfd17c)
    }

    @Test func flippedSeriesSwapsTheStackKeys() {
        typealias K = ViewInput.Key
        #expect(ViewInput.key(K.leftArrow, flippedData: true) == K.rightArrow)
        #expect(ViewInput.key(K.pageDown, flippedData: true) == K.pageUp)
        #expect(ViewInput.key(K.upArrow, flippedData: true) == K.upArrow)
        #expect(ViewInput.key(K.leftArrow, flippedData: false) == K.leftArrow)
    }

    @Test func doubleClickToleranceIsTheCsBits() {
        #expect(ViewInput.doubleClickTolerance(scale: 1.7).bitPattern == 0x40169696)
        #expect(ViewInput.doubleClickTolerance(scale: 0).bitPattern == 0x471c4000)
        #expect(ViewInput.doubleClickTolerance(scale: 3).bitPattern == 0x3faaaaab)
        let t = ViewInput.doubleClickTolerance(scale: 2)
        #expect(ViewInput.allPoints([CGPoint(x: 10, y: 10), CGPoint(x: 11.5, y: 8.5)], within: t, of: CGPoint(x: 10, y: 10)))
        #expect(!ViewInput.allPoints([CGPoint(x: 12.5, y: 10)], within: t, of: CGPoint(x: 10, y: 10)))
        #expect(ViewInput.allPoints([], within: t, of: .zero))
    }

    @Test func repulsorDistanceAndRadiusAreTheCs() {
        let click = CGPoint(x: 3.125, y: 7.75)
        let near = [CGPoint(x: 10.25, y: 20.5)]
        #expect(ViewInput.repulsorDistance(firstROI: near, pushedROIs: [near], click: click, pixelRatio: 0.6).bitPattern == 0x412743fb)
        #expect(ViewInput.repulsorDistance(firstROI: [CGPoint(x: 3.3, y: 4.4)], pushedROIs: [], click: CGPoint(x: 1.1, y: 2.2), pixelRatio: 1).bitPattern == 0x40471f0c)
        // The nearest point wins, from the first ROI's first point on.
        #expect(ViewInput.repulsorDistance(firstROI: [CGPoint(x: 10, y: 0)], pushedROIs: [[CGPoint(x: 10, y: 0), CGPoint(x: 3, y: 4)]], click: .zero, pixelRatio: 1) == 5)
        // Without a first ROI the repulsor pushes, nothing lowers 0.
        #expect(ViewInput.repulsorDistance(firstROI: nil, pushedROIs: [[CGPoint(x: 3, y: 4)]], click: .zero, pixelRatio: 1) == 0)
        #expect(ViewInput.repulsorRadius(distance: Float(bitPattern: 0x412743fb), imageWidth: 512) == 8)
        #expect(ViewInput.repulsorRadius(distance: 0.5, imageWidth: 512) == 2)
        #expect(ViewInput.repulsorRadius(distance: 1000, imageWidth: 512) == 256)
        #expect(ViewInput.repulsorRadius(distance: .nan, imageWidth: 512) == 2)
        #expect(ViewInput.pixelRatio(spacingX: 0.5, spacingY: 0.3) == Float(0.3 / 0.5))
        #expect(ViewInput.pixelRatio(spacingX: 0, spacingY: 0.3) == 1)
    }

    @Test func wheelIndexTruncatesAndClampsAsTheC() {
        let cases: [(Int, Double, Int, Int)] = [
            (5, 0.4, 5, 0), (5, 1.7, 6, 1), (5, -1.7, 4, -1), (5, -0.2, 5, 0),
            (32000, 40000, 72000, 40000), (32767, 1, 32768, 1), (32768, -1, 32767, -1),
            (2_147_483_000, 1e12, 2_147_483_647, 647), (-2_147_483_000, -1e12, -2_147_483_648, -648),
            (0, 3, 3, 3), (7, .infinity, 7, 0),
        ]
        for (current, change, index, increment) in cases {
            let r = WheelSteps.imageIndex(current, adding: change)
            #expect(r.index == index && r.increment == increment)
        }
    }

    @Test func movieIndexGoesAroundAsTheC() {
        #expect(WheelSteps.movieIndex(current: 0, count: 10, delta: -1) == 1)
        #expect(WheelSteps.movieIndex(current: 9, count: 10, delta: -3) == 1)
        #expect(WheelSteps.movieIndex(current: 3, count: 4, delta: 2.6) == 1)
        #expect(WheelSteps.movieIndex(current: 2, count: 5, delta: 1e12) == 2)
        #expect(WheelSteps.movieIndex(current: 2, count: 0, delta: 1) == 2)
        #expect(WheelSteps.movieIndex(current: 2, count: 5, delta: .nan) == 2)
    }

    @Test func wheelChangesAreAtLeastOneImage() {
        #expect(Float(-1.0) * Float(0.3) / Float(2.5) == Float(bitPattern: 0xbdf5c290))
        #expect(WheelSteps.stackChange(0.2) == 1)
        #expect(WheelSteps.stackChange(2.2) == 3)
        #expect(WheelSteps.stackChange(-0.2) == -1)
        #expect(WheelSteps.stackChange(-2.2) == -3)
        #expect(WheelSteps.imageChange(0.2, comPACS: false) == 1)
        #expect(WheelSteps.imageChange(1.7, comPACS: false) == 1.7)
        #expect(WheelSteps.imageChange(1.7, comPACS: true) == 1)
        #expect(WheelSteps.imageChange(0, comPACS: false) == -1)
        #expect(WheelSteps.imageChange(-2.5, comPACS: false) == -2.5)
        #expect(WheelSteps.imageChange(-2.5, comPACS: true) == -1)
    }

    @Test func slabStepsAccumulateTheTrackpadsFractions() {
        var remainder = 0.0
        #expect(WheelSteps.slabSteps(deltaY: 1, sign: 1, precise: true, remainder: &remainder) == 0)
        #expect(remainder == 0.40000000000000002)
        #expect(WheelSteps.slabSteps(deltaY: 1, sign: 1, precise: true, remainder: &remainder) == 0)
        #expect(remainder == 0.80000000000000004)
        #expect(WheelSteps.slabSteps(deltaY: -0.1, sign: -1, precise: false, remainder: &remainder) == 1)
        #expect(WheelSteps.slabSteps(deltaY: 500, sign: -1, precise: false, remainder: &remainder) == -128)
        #expect(WheelSteps.slabSteps(deltaY: 0, sign: 1, precise: true, remainder: &remainder) == nil)
    }

    @Test func scrollingPastAnEndGoesToTheNeighbouringSeries() {
        #expect(WheelSteps.seriesStep(imageIndex: -1, imageCount: 5, seriesIndex: 1, seriesCount: 3) == .previous)
        #expect(WheelSteps.seriesStep(imageIndex: -1, imageCount: 5, seriesIndex: 0, seriesCount: 3) == nil)
        #expect(WheelSteps.seriesStep(imageIndex: 5, imageCount: 5, seriesIndex: 1, seriesCount: 3) == .next)
        #expect(WheelSteps.seriesStep(imageIndex: 5, imageCount: 5, seriesIndex: 2, seriesCount: 3) == nil)
        #expect(WheelSteps.seriesStep(imageIndex: 2, imageCount: 5, seriesIndex: 1, seriesCount: 3) == nil)
        #expect(WheelSteps.seriesStep(imageIndex: -1, imageCount: 5, seriesIndex: nil, seriesCount: 3) == nil)
    }
}
