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

/// Where a view is in its stack of images and how the scroll wheel, the
/// trackpad, a drag and the slider move through it: the image shown, the image
/// a drag started from, the fractions an Option scroll of the slab has not yet
/// used, around the series or clamped at its ends, and when scrolling past an
/// end goes on to the next series of the study. DCMView keeps one value and
/// hands it the event's numbers; the view loads the image the index names.
public struct StackNavigation: Sendable, Equatable {

    /// The index of the image shown in the view's list; -1 with none.
    public var current: Int
    /// The image a drag through the stack started from.
    public var start: Int
    /// The fractions of slab steps a trackpad's Option scroll has made and
    /// not yet applied.
    public var slabRemainder: Double = 0
    /// When the last Option scroll came, from the event's clock.
    public var slabTimestamp: TimeInterval = 0
    /// Set by an Option scroll of a trackpad or of a gesture: its remaining
    /// finger and momentum events keep belonging to the slab.
    public var consumesSlabTail = false

    public init(current: Int = 0, start: Int = 0) {
        self.current = current
        self.start = start
    }

    // MARK: - The slab

    /// What a wheel event of a 2D viewer does to the slab.
    public enum SlabScroll: Sendable, Equatable {
        /// Not an Option scroll: the event moves through the stack.
        case stack
        /// Nothing happens: the tail of an Option gesture after Option was
        /// released, or an Option scroll too small to make a step.
        case none
        /// The slab gets thicker or thinner by these steps.
        case steps(Int)
    }

    /// A wheel event in a 2D viewer. A gesture that begins forgets the
    /// slab's fractions; once an Option gesture of the trackpad has begun, its
    /// finger and momentum events stay with the slab even after Option is
    /// released, so they turn into no slice, phase, zoom or blend input. An
    /// Option scroll (Option without Command or Shift) changes the thickness,
    /// accumulating a trackpad's fractions until they make a step; a pause of
    /// more than `WheelSteps.slabRemainderLifetime` forgets them. The sign is
    /// read only for an Option scroll.
    public mutating func slabScroll(deltaY: Float, sign: @autoclosure () -> Double, precise: Bool,
                                    begins: Bool, inGesture: Bool, inMomentum: Bool,
                                    option: Bool, timestamp: TimeInterval) -> SlabScroll {
        if begins {
            consumesSlabTail = false
            slabRemainder = 0
        }
        if consumesSlabTail && !option {
            if inMomentum || inGesture {
                return .none
            }
            consumesSlabTail = false // A fresh discrete wheel event.
        }
        if option {
            consumesSlabTail = precise || inGesture
            if timestamp - slabTimestamp > WheelSteps.slabRemainderLifetime {
                slabRemainder = 0
            }
            slabTimestamp = timestamp
            guard let steps = WheelSteps.slabSteps(deltaY: deltaY, sign: sign(), precise: precise, remainder: &slabRemainder),
                  steps != 0 else { return .none }
            return .steps(steps)
        }
        slabRemainder = 0
        return .stack
    }

    /// A new series: the slab's fractions and the time of the last Option
    /// scroll are forgotten.
    public mutating func forgetSlabScroll() {
        slabRemainder = 0
        slabTimestamp = 0
    }

    // MARK: - The wheel

    /// Shift and the wheel: whole stacks of `stackSize` images, at least one
    /// stack per event. `change` is the event's delta in images, with its
    /// sign. Returns the increment the synchronized views are sent.
    public mutating func scrollStacks(_ change: Float, stackSize: Int) -> Int {
        let steps = WheelSteps.stackChange(change)
        let moved = WheelSteps.imageIndex(current, adding: Double(stackSize) * Double(steps))
        current = moved.index
        return moved.increment
    }

    /// The wheel alone: a row of tiles per image the event moves by, at least
    /// one row, exactly one with the ComPACS plugin. Returns the increment the
    /// synchronized views are sent.
    public mutating func scrollImages(_ change: Float, rows: Int, columns: Int, comPACS: Bool) -> Int {
        let steps = WheelSteps.imageChange(change, comPACS: comPACS)
        let moved = WheelSteps.imageIndex(current, adding: Double(rows) * Double(columns) * Double(steps))
        current = moved.index
        return moved.increment
    }

    /// After a wheel event that did not go on to another series: a series of
    /// more than three images goes around when the wheel loops, from the
    /// first image to the last and back; otherwise the index stops at the
    /// ends.
    public mutating func endWheelStep(count: Int, loops: Bool) {
        if count > 3 && loops {
            if current < 0 { current = count - 1 }
            if Self.beyondLast(current, count) { current = 0 }
        } else {
            clamp(count: count)
        }
    }

    /// The index within the series: 0 before the first image, the last image
    /// after it.
    public mutating func clamp(count: Int) {
        if current < 0 { current = 0 }
        if Self.beyondLast(current, count) { current = count - 1 }
    }

    /// An index compared with a count as the Objective-C compared a short with
    /// an NSUInteger: as unsigned, so a negative index is past the end.
    static func beyondLast(_ index: Int, _ count: Int) -> Bool {
        UInt(bitPattern: index) >= UInt(bitPattern: count)
    }

    // MARK: - Scrolling through the study

    /// Past the first or the last image of a study that scrolls through its
    /// series: the series to load, the previous before the first image and the
    /// next after the last as the user sees them (a flipped series runs the
    /// other way), when there is one; `seriesPosition`, the series' index in the
    /// study (nil when it is not found) and the number of series, is asked only
    /// past an end. The index is then clamped to the series.
    public mutating func passEnd(count: Int, flipped: Bool,
                                 seriesPosition: () -> (index: Int?, count: Int)) -> WheelSteps.SeriesStep? {
        var step: WheelSteps.SeriesStep?
        let shown = flipped ? count - 1 - current : current
        if shown < 0 || shown >= count {
            let position = seriesPosition()
            step = WheelSteps.seriesStep(imageIndex: shown, imageCount: count, seriesIndex: position.index, seriesCount: position.count)
        }
        clamp(count: count)
        return step
    }

    /// The series a trackpad swipe loads, in the order they are loaded: a
    /// swipe to the left or up the next one, to the right or down the
    /// previous one, each axis beyond half a point.
    public static func swipeSteps(deltaX: Double, deltaY: Double) -> [WheelSteps.SeriesStep] {
        var steps: [WheelSteps.SeriesStep] = []
        if deltaX < -0.5 { steps.append(.next) }
        if deltaX > 0.5 { steps.append(.previous) }
        if deltaY < -0.5 { steps.append(.next) }
        if deltaY > 0.5 { steps.append(.previous) }
        return steps
    }

    // MARK: - The slider and the drag

    /// The viewer's slider moved to `value`, the image as the user sees it:
    /// the view's own index, from the end in a flipped series. Not clamped:
    /// the view clamps it as it shows the image.
    public mutating func slide(to value: Int, count: Int, flipped: Bool) {
        current = SeriesBrowsing.userIndex(ofViewImage: value, count: count, flipped: flipped)
    }

    /// The axis a drag through the stack takes, once the pointer has moved
    /// more than three points from where the drag began: 1 vertical, 2
    /// horizontal; 0 until then. A chosen axis stays.
    public static func dragAxis(_ axis: Int, from start: CGPoint, to point: CGPoint) -> Int {
        if axis != 0 { return axis }
        if abs(start.x - point.x) < abs(start.y - point.y) {
            if abs(start.y - point.y) > 3 { return 1 }
        } else if abs(start.x - point.x) >= abs(start.y - point.y) {
            if abs(start.x - point.x) > 3 { return 2 }
        }
        return axis
    }

    /// A drag through the stack from `start` to `point` along `axis`: half the
    /// view's extent on that axis (`size`) walks the whole series from the
    /// image the drag started on, in the direction `sign` gives (the wheel's
    /// direction, so the two gestures agree), clamped to the series. False,
    /// with the index unchanged, when it cannot move: no images, a pointer
    /// that is not finite, no axis yet or an empty view.
    public mutating func drag(from start: CGPoint, to point: CGPoint, axis: Int, size: CGSize,
                              count: Int, sign: Double) -> Bool {
        if count == 0 || !point.x.isFinite || !point.y.isFinite { return false }
        let extent: CGFloat = axis == 2 ? size.width : size.height
        if (axis != 1 && axis != 2) || !extent.isFinite || extent <= 0 { return false }
        var movement: Double = axis == 2 ? point.x - start.x : start.y - point.y
        movement *= sign
        let proposedIndex = Double(self.start) + movement * Double(count) / (extent / 2.0)
        if !proposedIndex.isFinite { return false }
        // Clamp in floating point before converting to the index.
        let lastIndex = Double(count) - 1
        current = Int(fmax(0, fmin(proposedIndex, lastIndex)))
        return true
    }
}
