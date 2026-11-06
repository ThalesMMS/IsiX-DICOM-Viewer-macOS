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

// The stack navigation of a view against the code DCMView ran before
// StackNavigation: each `Former` method is that code (the scroll wheel, the
// scroll through the study, the slider, the swipe and the drag through the
// stack) with the view's state turned into fields and its messages into
// results. They run on random inputs of a fixed seed and on edge cases, and
// the state and results must be the same.

/// A fixed-seed generator, so that a failure can be replayed.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// What the former slab section of -scrollWheel: did with an event.
private enum FormerSlab: Equatable {
    case goesOn, returned, adjusted(Int)
}

private struct Former {
    var horos_curImage = 0
    var horos_startImage = 0
    var horos_slabScrollRemainder: Double = 0
    var horos_slabScrollTimestamp: TimeInterval = 0
    var horos_consumeSlabScrollTail = false
    var horos_scrollMode = 0

    var stack: StackNavigation {
        var stack = StackNavigation(current: horos_curImage, start: horos_startImage)
        stack.slabRemainder = horos_slabScrollRemainder
        stack.slabTimestamp = horos_slabScrollTimestamp
        stack.consumesSlabTail = horos_consumeSlabScrollTail
        return stack
    }

    func same(_ stack: StackNavigation) -> Bool {
        stack.current == horos_curImage && stack.start == horos_startImage
            && stack.slabRemainder.bitPattern == horos_slabScrollRemainder.bitPattern
            && stack.slabTimestamp.bitPattern == horos_slabScrollTimestamp.bitPattern
            && stack.consumesSlabTail == horos_consumeSlabScrollTail
    }

    // The slab section of -scrollWheel: in a 2D viewer.
    mutating func slab(deltaY: Float, sign: Double, precise: Bool, phase: Set<String>, momentum: Bool,
                       slabGesture: Bool, timestamp: TimeInterval) -> FormerSlab {
        if phase.contains("began") || phase.contains("mayBegin") {
            self.horos_consumeSlabScrollTail = false
            self.horos_slabScrollRemainder = 0
        }
        if self.horos_consumeSlabScrollTail && !slabGesture {
            if momentum || !phase.isEmpty {
                return .returned
            }
            self.horos_consumeSlabScrollTail = false
        }
        if slabGesture {
            self.horos_consumeSlabScrollTail = precise || !phase.isEmpty
            if timestamp - self.horos_slabScrollTimestamp > WheelSteps.slabRemainderLifetime {
                self.horos_slabScrollRemainder = 0
            }
            self.horos_slabScrollTimestamp = timestamp
            var remainder = self.horos_slabScrollRemainder
            let steps = WheelSteps.slabSteps(deltaY: deltaY, sign: sign, precise: precise, remainder: &remainder)
            self.horos_slabScrollRemainder = remainder
            guard let steps else { return .returned }
            if steps != 0 {
                return .adjusted(steps)
            }
            return .returned
        }
        self.horos_slabScrollRemainder = 0
        return .goesOn
    }

    // The Shift and the plain branches of -scrollWheel:.
    mutating func wheel(deltaY: Float, reverseScrollWheel: Float, shift: Bool, stack: Int16,
                        rows: Int, columns: Int, comPACS: Bool) -> Int {
        var inc = 0
        if shift {
            let change = WheelSteps.stackChange(reverseScrollWheel * deltaY / 2.5)
            (self.horos_curImage, inc) = WheelSteps.imageIndex(self.horos_curImage, adding: Double(stack) * Double(change))
        } else {
            let change = WheelSteps.imageChange(reverseScrollWheel * deltaY / 2.5, comPACS: comPACS)
            (self.horos_curImage, inc) = WheelSteps.imageIndex(self.horos_curImage,
                                                               adding: Double(rows) * Double(columns) * Double(change))
        }
        return inc
    }

    // The end of -scrollWheel: when it did not go on to another series.
    mutating func endWheel(count: Int, loopScrollWheel: Bool) {
        if count > 3 && loopScrollWheel {
            if self.horos_curImage < 0 { self.horos_curImage = count - 1 }
            if UInt(bitPattern: self.horos_curImage) >= UInt(bitPattern: count) { self.horos_curImage = 0 }
        } else {
            if self.horos_curImage < 0 { self.horos_curImage = 0 }
            if UInt(bitPattern: self.horos_curImage) >= UInt(bitPattern: count) { self.horos_curImage = count - 1 }
        }
    }

    // -scrollThroughSeriesIfNecessary: once the study scrolls through its
    // series, with the series' place in the study.
    mutating func scrollThroughSeries(count: Int, flipped: Bool, seriesIndex: Int?, seriesCount: Int) -> WheelSteps.SeriesStep? {
        var step: WheelSteps.SeriesStep?
        var imIndex = Int(self.horos_curImage)
        if flipped {
            imIndex = count - 1 - imIndex
        }
        if imIndex < 0 || imIndex >= count {
            step = WheelSteps.seriesStep(imageIndex: imIndex, imageCount: count, seriesIndex: seriesIndex, seriesCount: seriesCount)
        }
        if self.horos_curImage < 0 { self.horos_curImage = 0 }
        if UInt(bitPattern: self.horos_curImage) >= UInt(bitPattern: count) { self.horos_curImage = count - 1 }
        return step
    }

    // -sliderAction:, before -setIndex: clamps.
    mutating func slider(value: Int, count: Int, flipped: Bool) {
        if flipped {
            self.horos_curImage = count - 1 - value
        } else {
            self.horos_curImage = value
        }
    }

    // -swipeWithEvent: in a 2D viewer: true loads the series up, false down.
    static func swipe(deltaX: Double, deltaY: Double) -> [Bool] {
        var loads: [Bool] = []
        if deltaX < -0.5 { loads.append(true) }
        if deltaX > 0.5 { loads.append(false) }
        if deltaY < -0.5 { loads.append(true) }
        if deltaY > 0.5 { loads.append(false) }
        return loads
    }

    // -mouseDraggedImageScroll: up to the index; false where it returned.
    mutating func drag(start: CGPoint, current: CGPoint, frame: CGSize, count: Int, sign: Double) -> Bool {
        if self.horos_scrollMode == 0 {
            if abs(start.x - current.x) < abs(start.y - current.y) {
                if abs(start.y - current.y) > 3 { self.horos_scrollMode = 1 }
            } else if abs(start.x - current.x) >= abs(start.y - current.y) {
                if abs(start.x - current.x) > 3 { self.horos_scrollMode = 2 }
            }
        }
        if count == 0 || !current.x.isFinite || !current.y.isFinite { return false }
        let scrollMode = self.horos_scrollMode
        let extent: CGFloat = scrollMode == 2 ? frame.width : frame.height
        if (scrollMode != 1 && scrollMode != 2) || !extent.isFinite || extent <= 0 { return false }
        var movement: Double = scrollMode == 2 ? current.x - start.x : start.y - current.y
        movement *= sign
        let proposedIndex = Double(self.horos_startImage) + movement * Double(count) / (extent / 2.0)
        if !proposedIndex.isFinite { return false }
        let lastIndex = Double(count) - 1
        self.horos_curImage = Int(fmax(0, fmin(proposedIndex, lastIndex)))
        return true
    }
}

private func randomIndex(_ g: inout SplitMix) -> Int {
    switch Int.random(in: 0..<10, using: &g) {
    case 0: return -Int.random(in: 1...40, using: &g)
    case 1: return Int(Int16.max) + Int.random(in: -3...3, using: &g)
    case 2: return Int(Int32.max) - Int.random(in: 0...2, using: &g)
    default: return Int.random(in: 0...300, using: &g)
    }
}

private func randomDelta(_ g: inout SplitMix) -> Float {
    switch Int.random(in: 0..<12, using: &g) {
    case 0: return 0
    case 1: return [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude, 1e12, -1e12].randomElement(using: &g)!
    case 2: return Float.random(in: -0.4...0.4, using: &g)
    default: return Float.random(in: -40...40, using: &g)
    }
}

@Suite struct StackNavigationTests {

    @Test func slabScrollMatchesTheFormerWheel() {
        var g = SplitMix(state: 0x51AB)
        let phases: [Set<String>] = [[], ["began"], ["mayBegin"], ["changed"], ["ended"], ["began", "changed"]]
        for _ in 0..<200 {
            var former = Former()
            var stack = former.stack
            var clock = Double.random(in: 0...1000, using: &g)
            for _ in 0..<100 {
                clock += [0.01, 0.1, 0.29, 0.31, 2].randomElement(using: &g)!
                let deltaY = randomDelta(&g), sign: Double = Bool.random(using: &g) ? 1 : -1
                let precise = Bool.random(using: &g), momentum = Int.random(in: 0..<4, using: &g) == 0
                let phase = phases.randomElement(using: &g)!, option = Int.random(in: 0..<3, using: &g) != 0
                let expected = former.slab(deltaY: deltaY, sign: sign, precise: precise, phase: phase, momentum: momentum,
                                           slabGesture: option, timestamp: clock)
                let result = stack.slabScroll(deltaY: deltaY, sign: sign, precise: precise,
                                              begins: phase.contains("began") || phase.contains("mayBegin"),
                                              inGesture: !phase.isEmpty, inMomentum: momentum, option: option, timestamp: clock)
                switch (expected, result) {
                case (.goesOn, .stack), (.returned, .none): break
                case (.adjusted(let a), .steps(let b)) where a == b: break
                default: Issue.record("\(expected) became \(result)")
                }
                #expect(former.same(stack))
            }
        }
    }

    @Test func theSignIsReadOnlyForAnOptionScroll() {
        var stack = StackNavigation()
        var reads = 0
        func sign() -> Double { reads += 1; return 1 }
        // Outside #expect, which evaluates the arguments it shows.
        let wheel = stack.slabScroll(deltaY: 5, sign: sign(), precise: false, begins: false, inGesture: false, inMomentum: false,
                                     option: false, timestamp: 1)
        #expect(wheel == .stack && reads == 0)
        let slab = stack.slabScroll(deltaY: 5, sign: sign(), precise: false, begins: false, inGesture: false, inMomentum: false,
                                    option: true, timestamp: 2)
        #expect(slab == .steps(2) && reads == 1)
    }

    @Test func aTrackpadOptionGestureKeepsItsTail() {
        var stack = StackNavigation()
        // A trackpad's Option scroll accumulates its fractions until they make a step.
        #expect(stack.slabScroll(deltaY: 1, sign: 1, precise: true, begins: true, inGesture: true, inMomentum: false,
                                 option: true, timestamp: 1) == .none)
        #expect(stack.slabScroll(deltaY: 2, sign: 1, precise: true, begins: false, inGesture: true, inMomentum: false,
                                 option: true, timestamp: 1.1) == .steps(1))
        #expect(stack.consumesSlabTail)
        // Option released: the gesture's finger and momentum events stay with the slab.
        #expect(stack.slabScroll(deltaY: 9, sign: 1, precise: true, begins: false, inGesture: true, inMomentum: false,
                                 option: false, timestamp: 1.2) == .none)
        #expect(stack.slabScroll(deltaY: 9, sign: 1, precise: true, begins: false, inGesture: false, inMomentum: true,
                                 option: false, timestamp: 1.3) == .none)
        // A fresh wheel event goes through the stack again.
        #expect(stack.slabScroll(deltaY: 9, sign: 1, precise: false, begins: false, inGesture: false, inMomentum: false,
                                 option: false, timestamp: 1.4) == .stack)
        #expect(!stack.consumesSlabTail && stack.slabRemainder == 0)
        // A new series forgets the fractions and the time, not the tail.
        stack.slabRemainder = 0.7; stack.slabTimestamp = 9; stack.consumesSlabTail = true
        stack.forgetSlabScroll()
        #expect(stack.slabRemainder == 0 && stack.slabTimestamp == 0 && stack.consumesSlabTail)
    }

    @Test func wheelStepsMatchTheFormerWheel() {
        var g = SplitMix(state: 0x3EE1)
        for _ in 0..<40_000 {
            let current = randomIndex(&g), deltaY = randomDelta(&g)
            let reverse: Float = Bool.random(using: &g) ? 1 : -1, shift = Bool.random(using: &g)
            let stackSize = Int16.random(in: 0...12, using: &g)
            let rows = Int.random(in: 1...4, using: &g), columns = Int.random(in: 1...4, using: &g)
            let comPACS = Int.random(in: 0..<5, using: &g) == 0
            var former = Former(horos_curImage: current)
            let expected = former.wheel(deltaY: deltaY, reverseScrollWheel: reverse, shift: shift, stack: stackSize,
                                        rows: rows, columns: columns, comPACS: comPACS)
            var stack = StackNavigation(current: current)
            let change = reverse * deltaY / 2.5
            let increment = shift ? stack.scrollStacks(change, stackSize: Int(stackSize))
                                  : stack.scrollImages(change, rows: rows, columns: columns, comPACS: comPACS)
            #expect(increment == expected && stack.current == former.horos_curImage,
                    "\(current) \(deltaY) shift \(shift) stack \(stackSize) \(rows)x\(columns)")
        }
    }

    @Test func theWheelLoopsOrStopsAsBefore() {
        var g = SplitMix(state: 0x100B)
        for _ in 0..<20_000 {
            let count = [0, 1, 2, 3, 4, 5, 16, 300].randomElement(using: &g)!
            let current = Bool.random(using: &g) ? Int.random(in: -3...(count + 3), using: &g) : randomIndex(&g)
            let loops = Bool.random(using: &g)
            var former = Former(horos_curImage: current)
            former.endWheel(count: count, loopScrollWheel: loops)
            var stack = StackNavigation(current: current)
            stack.endWheelStep(count: count, loops: loops)
            #expect(stack.current == former.horos_curImage, "\(current) of \(count), loops \(loops)")
        }
        var stack = StackNavigation(current: 16)
        stack.endWheelStep(count: 16, loops: true)
        #expect(stack.current == 0, "past the last image, around")
        stack.current = -1
        stack.endWheelStep(count: 16, loops: true)
        #expect(stack.current == 15, "before the first image, around")
        stack.current = 4
        stack.endWheelStep(count: 3, loops: true)
        #expect(stack.current == 2, "three images or fewer stop at the ends")
    }

    @Test func scrollingPastAnEndGoesOnAsBefore() {
        var g = SplitMix(state: 0xE4D)
        for _ in 0..<20_000 {
            let count = [0, 1, 2, 5, 40].randomElement(using: &g)!
            let current = Int.random(in: -4...(count + 4), using: &g)
            let flipped = Bool.random(using: &g)
            let seriesCount = Int.random(in: 0...4, using: &g)
            let seriesIndex: Int? = Int.random(in: 0..<4, using: &g) == 0 ? nil : Int.random(in: 0...max(0, seriesCount - 1), using: &g)
            var former = Former(horos_curImage: current)
            let expected = former.scrollThroughSeries(count: count, flipped: flipped, seriesIndex: seriesIndex, seriesCount: seriesCount)
            var stack = StackNavigation(current: current)
            var asked = false
            let step = stack.passEnd(count: count, flipped: flipped) { asked = true; return (seriesIndex, seriesCount) }
            #expect(step == expected && stack.current == former.horos_curImage)
            let shown = flipped ? count - 1 - current : current
            #expect(asked == (shown < 0 || shown >= count), "the study is asked only past an end")
        }
        var stack = StackNavigation(current: 10)
        #expect(stack.passEnd(count: 10, flipped: false) { (1, 3) } == .next && stack.current == 9)
        stack.current = -1
        #expect(stack.passEnd(count: 10, flipped: false) { (1, 3) } == .previous && stack.current == 0)
        stack.current = -1
        #expect(stack.passEnd(count: 10, flipped: true) { (1, 3) } == .next, "a flipped series runs the other way")
        stack.current = 10
        #expect(stack.passEnd(count: 10, flipped: false) { (2, 3) } == nil, "the last series of the study")
    }

    @Test func theSliderAndTheSwipeAsBefore() {
        for count in [0, 1, 7] { for value in -2...9 { for flipped in [false, true] {
            var former = Former(horos_curImage: 3)
            former.slider(value: value, count: count, flipped: flipped)
            var stack = StackNavigation(current: 3)
            stack.slide(to: value, count: count, flipped: flipped)
            #expect(stack.current == former.horos_curImage)
        } } }
        let deltas: [Double] = [-3, -0.6, -0.5, -0.1, 0, 0.1, 0.5, 0.6, 3, .nan]
        for x in deltas { for y in deltas {
            let steps = StackNavigation.swipeSteps(deltaX: x, deltaY: y)
            #expect(steps.map { $0 == .next } == Former.swipe(deltaX: x, deltaY: y), "\(x) \(y)")
        } }
    }

    @Test func theDragMatchesTheFormerDrag() {
        var g = SplitMix(state: 0xD2A6)
        func coordinate(_ g: inout SplitMix) -> CGFloat {
            switch Int.random(in: 0..<20, using: &g) {
            case 0: return CGFloat.nan
            case 1: return CGFloat.infinity
            case 2: return CGFloat(Double.random(in: -1e12...1e12, using: &g))
            default: return CGFloat(Double.random(in: -400...400, using: &g))
            }
        }
        for _ in 0..<40_000 {
            let start = CGPoint(x: CGFloat(Double.random(in: -50...50, using: &g)), y: CGFloat(Double.random(in: -50...50, using: &g)))
            let point = CGPoint(x: coordinate(&g), y: coordinate(&g))
            let widths: [CGFloat] = [0, 1, 100, 400, CGFloat.infinity], heights: [CGFloat] = [0, 1, 200, 300, CGFloat.nan]
            let size = CGSize(width: widths.randomElement(using: &g)!, height: heights.randomElement(using: &g)!)
            let count = [0, 1, 2, 20, 300].randomElement(using: &g)!
            let mode = [0, 0, 1, 2, 3].randomElement(using: &g)!
            let startImage = Int.random(in: 0...max(0, count), using: &g), current = Int.random(in: 0...max(0, count), using: &g)
            let sign: Double = Bool.random(using: &g) ? 1 : -1
            var former = Former(horos_curImage: current, horos_startImage: startImage, horos_scrollMode: mode)
            let expected = former.drag(start: start, current: point, frame: size, count: count, sign: sign)
            let axis = StackNavigation.dragAxis(mode, from: start, to: point)
            var stack = StackNavigation(current: current, start: startImage)
            let moved = stack.drag(from: start, to: point, axis: axis, size: size, count: count, sign: sign)
            #expect(axis == former.horos_scrollMode)
            #expect(moved == expected && stack.current == former.horos_curImage, "\(start) \(point) \(size) \(count) \(mode)")
        }
    }
}
