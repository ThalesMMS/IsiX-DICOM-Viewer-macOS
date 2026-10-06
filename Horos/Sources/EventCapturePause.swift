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

import AppKit
import Synchronization

/// Distinguishes a 1–2 s input hole from a main-thread stall.
///
/// The 2017 report (horosproject/horos#194) saw brush, database scrolling
/// and image scrolling all stop registering events for about a second.
/// That is not the same contract as the database matrix click-hold (1 s)
/// or the thumbnail hold-to-drag (2 s). Those two waits start a drag;
/// they are not a stall during an already-running gesture.
///
/// A gap is only a main-thread stall when the heartbeat stops too. A gap
/// with a live heartbeat is event absence. Neither reading invents a
/// cause — previous use of another application is not treated as proof.
@objc(HorosEventCapturePauseKind)
public enum EventCapturePauseKind: Int, Sendable {
    case withinCadence = 1
    case eventAbsence = 2
    case mainBlocked = 3
}

@objc(HorosEventCapturePauseSample)
public final class EventCapturePauseSample: NSObject, Sendable {
    @objc public let drawTicks: Int
    @objc public let heartbeatTicks: Int
    @objc public let maxDrawGap: TimeInterval
    @objc public let maxHeartbeatGap: TimeInterval
    @objc public let duration: TimeInterval
    @objc public let kind: EventCapturePauseKind
    @objc public let backgroundIterations: Int

    @objc public init(
        drawTicks: Int,
        heartbeatTicks: Int,
        maxDrawGap: TimeInterval,
        maxHeartbeatGap: TimeInterval,
        duration: TimeInterval,
        kind: EventCapturePauseKind,
        backgroundIterations: Int
    ) {
        self.drawTicks = drawTicks
        self.heartbeatTicks = heartbeatTicks
        self.maxDrawGap = maxDrawGap
        self.maxHeartbeatGap = maxHeartbeatGap
        self.duration = duration
        self.kind = kind
        self.backgroundIterations = backgroundIterations
        super.init()
    }
}

@objc(HorosEventCapturePause)
public final class EventCapturePause: NSObject {
    @objc public static let historicalPauseMinimum: TimeInterval = 1.0
    @objc public static let historicalPauseMaximum: TimeInterval = 2.0
    @objc public static let databaseClickHoldLimit: TimeInterval = 1.0
    @objc public static let thumbnailHoldToDragLimit: TimeInterval = 2.0
    @objc public static let drawTickInterval: TimeInterval = 0.01

    @objc(classifyEventGap:heartbeatGap:)
    public static func classify(eventGap: TimeInterval, heartbeatGap: TimeInterval) -> EventCapturePauseKind {
        if eventGap < historicalPauseMinimum {
            return .withinCadence
        }
        if heartbeatGap >= historicalPauseMinimum {
            return .mainBlocked
        }
        return .eventAbsence
    }

    @objc(largestGapIn:)
    public static func largestGap(in stamps: [TimeInterval]) -> TimeInterval {
        guard stamps.count >= 2 else { return 0 }
        var widest: TimeInterval = 0
        for index in 1..<stamps.count {
            widest = max(widest, stamps[index] - stamps[index - 1])
        }
        return widest
    }

    /// Pump default and event-tracking modes with a draw tick, a heartbeat
    /// and a background worker. This is the host run-loop, not Horos.app.
    @objc(measureHostRunLoopDuration:)
    public static func measureHostRunLoop(duration: TimeInterval) -> EventCapturePauseSample {
        precondition(Thread.isMainThread, "the run-loop probe has to own the main thread")
        return MainActor.assumeIsolated { measureOnMainRunLoop(duration: duration) }
    }

    @MainActor
    private static func measureOnMainRunLoop(duration: TimeInterval) -> EventCapturePauseSample {
        NSApplication.shared.setActivationPolicy(.accessory)

        // The timers fire on this run loop, the main one: the stamps stay on
        // the main actor, and each tick asserts it instead of sharing an array.
        let draws = TickStamps()
        let beats = TickStamps()
        let started = ProcessInfo.processInfo.systemUptime
        let draw = Timer(timeInterval: drawTickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { draws.values.append(ProcessInfo.processInfo.systemUptime) }
        }
        let beat = Timer(timeInterval: drawTickInterval, repeats: true) { _ in
            MainActor.assumeIsolated { beats.values.append(ProcessInfo.processInfo.systemUptime) }
        }
        for mode in [RunLoop.Mode.default, RunLoop.Mode.eventTracking, RunLoop.Mode.common] {
            RunLoop.current.add(draw, forMode: mode)
            RunLoop.current.add(beat, forMode: mode)
        }

        let counter = IterationCounter()
        let until = started + duration
        DispatchQueue.global(qos: .userInitiated).async {
            var acc: UInt64 = 1
            while ProcessInfo.processInfo.systemUptime < until {
                acc = acc &* 6_364_136_223_846_793_005 &+ 1
                counter.add()
            }
            _ = acc
        }

        let deadline = Date(timeIntervalSinceNow: duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.016))
            RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.016))
        }
        draw.invalidate()
        beat.invalidate()

        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let drawGap = largestGap(in: draws.values)
        let beatGap = largestGap(in: beats.values)
        return EventCapturePauseSample(
            drawTicks: draws.values.count,
            heartbeatTicks: beats.values.count,
            maxDrawGap: drawGap,
            maxHeartbeatGap: beatGap,
            duration: elapsed,
            kind: classify(eventGap: drawGap, heartbeatGap: beatGap),
            backgroundIterations: counter.value
        )
    }
}

/// The stamps of one timer, appended only on the main run loop that fires it.
@MainActor
private final class TickStamps {
    var values: [TimeInterval] = []
}

/// Counted by the background worker and read on the main thread when the
/// sample ends; the Mutex is the lock the counter always had.
private final class IterationCounter: Sendable {
    private let count = Mutex(0)

    func add() {
        count.withLock { $0 += 1 }
    }

    var value: Int {
        count.withLock { $0 }
    }
}
