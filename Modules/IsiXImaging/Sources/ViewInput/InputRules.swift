/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL
  
  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import CoreGraphics
import Foundation

/// The rules DCMView applies to the mouse, the keyboard, the scroll wheel and
/// the trackpad that need neither the view nor AppKit: which tool a click
/// uses, which cursor a tool shows, what the modifiers turn on, how far the
/// wheel moves through the images, the movie or the slab, when it goes on to
/// the next series, and the repulsor's radius. The view reads the event and
/// the image; these turn them into numbers and decisions.
public enum ViewInput {

    // MARK: - Tools

    /// The values of DCMView.h's ToolMode these rules name.
    public enum Tool {
        public static let windowLevel: Int16 = 0
        public static let translate: Int16 = 1
        public static let zoom: Int16 = 2
        public static let rotate: Int16 = 3
        public static let next: Int16 = 4
        public static let rotate3D: Int16 = 7
        public static let cross: Int16 = 8
        public static let text: Int16 = 13
        public static let camera3D: Int16 = 18
        public static let windowLevelBlended: Int16 = 22
        public static let repulsor: Int16 = 23
        public static let roiSelector: Int16 = 25
    }

    /// The modifier keys of an event, with NSEvent.ModifierFlags' raw values.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let capsLock = Modifiers(rawValue: 1 << 16)
        public static let shift = Modifiers(rawValue: 1 << 17)
        public static let control = Modifiers(rawValue: 1 << 18)
        public static let option = Modifiers(rawValue: 1 << 19)
        public static let command = Modifiers(rawValue: 1 << 20)
    }

    // The same bits as literals. These rules run at every mouse event; an
    // OptionSet built from an array literal costs, in an unoptimized build,
    // more than the event's own work, so the rules test the raw value.
    private static var shiftBit: UInt { 1 << 17 }
    private static var controlBit: UInt { 1 << 18 }
    private static var optionBit: UInt { 1 << 19 }
    private static var commandBit: UInt { 1 << 20 }

    /// The button an event comes from, as getTool: tells them apart.
    public enum Button: Sendable {
        /// The left button, a key or anything else: the left tool.
        case left
        /// A right-button down or drag.
        case right
        /// Another button's down or drag, with its number.
        case other(buttonNumber: Int)
    }

    /// The tool an event works with. The button picks the left, right or
    /// middle tool (the other buttons, often back and forward, move the
    /// image: a ROI tool there would draw with a button meant to navigate),
    /// then the modifiers override it: Command moves, Option alone windows,
    /// Control-Option windows the blended image when there is one, and,
    /// unless the left tool works on ROIs, Command-Option rotates and Shift
    /// zooms. With a ROI tool, Command-Option still rotates; Shift is the
    /// lens and leaves the tool alone.
    public static func tool(button: Button, left: Int16, right: Int16, middle: Int16,
                            modifiers: Modifiers, leftDrawsROIs: Bool, hasBlending: Bool) -> Int16 {
        // The ToolMode values are written out (Tool's names in the comments):
        // a static let is read through an accessor in an unoptimized build.
        let m = modifiers.rawValue
        let shift: UInt = 1 << 17, control: UInt = 1 << 18, option: UInt = 1 << 19, command: UInt = 1 << 20
        var tool: Int16
        switch button {
        case .left: tool = left
        case .right: tool = right
        case .other(let number): tool = number == 2 ? middle : 1 // translate
        }

        if m & command != 0 { tool = 1 } // translate
        if m & (shift | option) == option { tool = 0 } // windowLevel
        if m & control != 0 && m & option != 0 {
            tool = hasBlending ? 22 : 0 // windowLevelBlended, windowLevel
        }

        if !leftDrawsROIs && left != 25 { // roiSelector
            if m & command != 0 && m & option != 0 { tool = 3 } // rotate
            if m & shift != 0 { tool = 2 } // zoom
        } else {
            if m & command != 0 && m & option != 0 { tool = 3 } // rotate
        }
        return tool
    }

    /// A ROI or measuring tool (the values from tMesure on) takes the first
    /// click in a viewer that is not the key window when the application is
    /// active, so two viewers side by side are measured in turn; coming from
    /// another application, the click only brings the window forward. The
    /// other tools always take it.
    public static func acceptsFirstMouse(tool: Int16, applicationIsActive: Bool) -> Bool {
        tool >= 5 ? applicationIsActive : true
    }

    /// The cursors DCMView shows.
    public enum Cursor: Sendable, Equatable {
        case arrow, cross, openHand, rotate, zoom, contrast, stack, iBeam, crosshair, rotate3DCamera
    }

    /// The cursor of a tool: a cross for the ROI tools, then each tool's own.
    public static func cursor(for tool: Int16, drawsROIs: Bool) -> Cursor {
        if drawsROIs { return .cross }
        switch tool {
        case Tool.translate: return .openHand
        case Tool.rotate: return .rotate
        case Tool.zoom: return .zoom
        case Tool.windowLevel: return .contrast
        case Tool.next: return .stack
        case Tool.text: return .iBeam
        case Tool.rotate3D, Tool.cross, Tool.repulsor, Tool.roiSelector: return .crosshair
        case Tool.camera3D: return .rotate3DCamera
        default: return .arrow
        }
    }

    // MARK: - Modifiers

    /// Command-Shift hides the labels while it is held.
    public static func suppressesLabels(_ modifiers: Modifiers) -> Bool {
        modifiers.rawValue & (commandBit | shiftBit) == commandBit | shiftBit
    }

    /// Control alone shows the description in large.
    public static func showsDescriptionInLarge(_ modifiers: Modifiers) -> Bool {
        modifiers.rawValue & (controlBit | commandBit | shiftBit | optionBit) == controlBit
    }

    /// Shift without Option, Command or Control: the magnifying lens.
    public static func isShiftAlone(_ modifiers: Modifiers) -> Bool {
        modifiers.rawValue & (shiftBit | commandBit | controlBit | optionBit) == shiftBit
    }

    /// Shift and Control together: the patient crosshair follows the mouse.
    public static func syncsPatientPoint(_ modifiers: Modifiers) -> Bool {
        modifiers.rawValue & (shiftBit | controlBit) == shiftBit | controlBit
    }

    /// A double-click with the rotate tool turns the image a quarter to the
    /// right, a quarter to the left with Shift, half a turn with Option.
    public static func rotationAfterDoubleClick(_ rotation: Float, modifiers: Modifiers) -> Float {
        if modifiers.contains(.option) { return rotation - 180 }
        if modifiers.contains(.shift) { return rotation - 90 }
        return rotation + 90
    }

    /// The rotation a rotate drag starts from: the angle of the click seen
    /// from the view's centre is taken off, so the drag turns the image by the
    /// angle the pointer turns. A flipped axis turns the other way. The
    /// arithmetic is the C's, in double, stored as float.
    public static func rotationStart(_ rotationStart: Float, fromCenter point: CGPoint,
                                     xFlipped: Bool, yFlipped: Bool, deg2rad: Double) -> Float {
        var sign: Float = 1
        if xFlipped { sign = -sign }
        if yFlipped { sign = -sign }
        return Float(Double(rotationStart) - Double(sign) * atan2(Double(point.x), Double(point.y)) / deg2rad)
    }

    // MARK: - Keys

    /// Function keys of NSEvent's character set.
    public enum Key {
        public static let upArrow: UInt16 = 0xF700
        public static let downArrow: UInt16 = 0xF701
        public static let leftArrow: UInt16 = 0xF702
        public static let rightArrow: UInt16 = 0xF703
        public static let home: UInt16 = 0xF729
        public static let end: UInt16 = 0xF72B
        public static let pageUp: UInt16 = 0xF72C
        public static let pageDown: UInt16 = 0xF72D
    }

    /// In a series shown in reverse order, the arrows and the page keys go the
    /// other way through the stack, so that they keep their direction on screen.
    public static func key(_ character: UInt16, flippedData: Bool) -> UInt16 {
        guard flippedData else { return character }
        switch character {
        case Key.leftArrow: return Key.rightArrow
        case Key.rightArrow: return Key.leftArrow
        case Key.pageUp: return Key.pageDown
        case Key.pageDown: return Key.pageUp
        default: return character
        }
    }

    // MARK: - ROIs under a double-click

    /// The distance, in image pixels, within which the points of the ROI a
    /// double-click's first click started count as the click's own.
    public static func doubleClickTolerance(scale: Float) -> Float {
        Float(4.0 / (Double(scale) > 0.0001 ? Double(scale) : 0.0001))
    }

    /// Whether every point is within the tolerance of the click.
    public static func allPoints(_ points: [CGPoint], within tolerance: Float, of click: CGPoint) -> Bool {
        for p in points {
            let dx = abs(Double(Float(p.x)) - Double(click.x))
            let dy = abs(Double(Float(p.y)) - Double(click.y))
            if dx > Double(tolerance) || dy > Double(tolerance) { return false }
        }
        return true
    }

    // MARK: - Repulsor

    /// The distance from the click to the nearest point of the ROIs the
    /// repulsor pushes, with the rows scaled by the pixels' aspect ratio. It
    /// starts at the first point of the first ROI when that ROI is one the
    /// repulsor pushes, and at 0 otherwise, which no point can lower.
    public static func repulsorDistance(firstROI: [CGPoint]?, pushedROIs: [[CGPoint]],
                                        click: CGPoint, pixelRatio: Float) -> Float {
        func distance(_ pt: CGPoint) -> Float {
            let dx = Float(pt.x - click.x)
            let dx2 = dx * dx
            let dy = Float((pt.y - click.y) * CGFloat(pixelRatio))
            let dy2 = dy * dy
            return Float(sqrt(Double(dx2 + dy2)))
        }
        var result: Float = 0
        if let first = firstROI?.first { result = distance(first) }
        for points in pushedROIs {
            for pt in points {
                let d = distance(pt)
                result = d < result ? d : result
            }
        }
        return result
    }

    /// The repulsor's radius from that distance: four fifths of it, from 2
    /// pixels to half the image's width.
    public static func repulsorRadius(distance: Float, imageWidth: Int) -> Int32 {
        var radius = cInt32((Double(distance) + 0.5) * 0.8)
        if radius < 2 { radius = 2 }
        if Int(radius) > imageWidth / 2 { radius = Int32(truncatingIfNeeded: imageWidth / 2) }
        return radius
    }

    /// A double converted to int as the arm64 code of the C does (fcvtzs):
    /// toward zero, saturated, NaN to 0.
    static func cInt32(_ x: Double) -> Int32 {
        if x.isNaN { return 0 }
        if x >= 2147483647.0 { return Int32.max }
        if x <= -2147483648.0 { return Int32.min }
        return Int32(x)
    }

    /// The ratio the repulsor scales the rows by: 1 without both spacings.
    public static func pixelRatio(spacingX: Double, spacingY: Double) -> Float {
        var ratio: Float = 1.0
        if spacingY != 0 && spacingX != 0 { ratio = Float(spacingY / spacingX) }
        return ratio
    }
}

/// How far the scroll wheel and the trackpad move through a series, its
/// movie and its slab.
public enum WheelSteps {

    /// The image index after adding a wheel change, and the increment the
    /// synchronized viewers are sent. Ordinary steps truncate toward zero; the
    /// index is clamped to the 32-bit range before it is converted, so a large
    /// event cannot wrap it to the other end of the series, while a series of
    /// more than 32767 images is stepped through whole. A change that is not
    /// finite moves nothing.
    public static func imageIndex(_ current: Int, adding change: Double) -> (index: Int, increment: Int) {
        if !change.isFinite { return (current, 0) }
        let lowest = Double(Int32.min), highest = Double(Int32.max)
        let next = Swift.max(lowest, Swift.min(highest, Double(current) + change.rounded(.towardZero)))
        let increment = Int(Swift.max(lowest, Swift.min(highest, next - Double(current))))
        return (Int(next), increment)
    }

    /// The movie index a 4D scroll goes to: at least one frame per event,
    /// around the movie. The change is reduced before it is added, as repeated
    /// subtraction of large floats can stall.
    public static func movieIndex(current: Int, count: Int, delta: Double) -> Int {
        if count <= 0 || !delta.isFinite || delta == 0 { return current }
        var change = delta / -2.5
        change = change >= 0 ? Swift.max(1, change.rounded(.up)) : Swift.min(-1, change.rounded(.down))
        var result = fmod(Double(current) + fmod(change, Double(count)), Double(count))
        if result < 0 { result += Double(count) }
        return Int(result)
    }

    /// The images Shift scrolls by, in stacks: whole, at least one.
    public static func stackChange(_ change: Float) -> Float {
        if change >= 0 {
            var c = change.rounded(.up)
            if c < 1 { c = 1 }
            return c
        }
        var c = change.rounded(.down)
        if c > -1 { c = -1 }
        return c
    }

    /// The images the wheel scrolls by: at least one, exactly one with the
    /// ComPACS plugin; no change counts as backwards.
    public static func imageChange(_ change: Float, comPACS: Bool) -> Float {
        if change > 0 {
            if comPACS { return 1 }
            return change < 1 ? 1 : change
        }
        if comPACS { return -1 }
        return change > -1 ? -1 : change
    }

    /// The slab steps an Option scroll makes, nil when it makes no change. A
    /// precise (trackpad) scroll accumulates its fractions in `remainder`; a
    /// wheel makes at least one step. The change is bounded to 128 steps.
    public static func slabSteps(deltaY: Float, sign: Double, precise: Bool, remainder: inout Double) -> Int? {
        var change = sign * Double(deltaY) / 2.5
        if change == 0 { return nil }
        change = Swift.max(-128, Swift.min(128, change))
        if precise {
            remainder += change
            let steps = Int(remainder.rounded(.towardZero))
            remainder -= Double(steps)
            return steps
        }
        return change > 0 ? Int(change.rounded(.up)) : Int(change.rounded(.down))
    }

    /// The pause after which a slab scroll's fractions are forgotten.
    public static let slabRemainderLifetime: TimeInterval = 0.3

    /// Where scrolling past an end of the series goes when it scrolls through
    /// the series of the study.
    public enum SeriesStep: Sendable, Equatable {
        case previous, next
    }

    /// The series to load when the image index, in the series' own order, has
    /// gone past one of its ends: the previous series before the first image,
    /// the next after the last, if there is one; nil inside the series or at
    /// the study's first or last series.
    public static func seriesStep(imageIndex: Int, imageCount: Int, seriesIndex: Int?, seriesCount: Int) -> SeriesStep? {
        guard let seriesIndex else { return nil }
        if imageIndex < 0 { return seriesIndex > 0 ? .previous : nil }
        if imageIndex >= imageCount { return seriesIndex + 1 < seriesCount ? .next : nil }
        return nil
    }
}
