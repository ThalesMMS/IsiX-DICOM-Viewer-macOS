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

/// Decision for one step of drawing or concluding a Curved MPR centreline.
@objc(HorosCurvedMPRPathDecision)
public final class CurvedMPRPathDecision: NSObject {
    @objc public let accepted: Bool
    @objc public let phase: String
    @objc public let diagnosis: String
    @objc public let nodeCount: Int

    @objc public init(accepted: Bool, phase: String, diagnosis: String, nodeCount: Int) {
        self.accepted = accepted
        self.phase = phase
        self.diagnosis = diagnosis
        self.nodeCount = nodeCount
    }
}

/// Patient-space nodes for a Curved MPR path. Origin is valid; NaN is not.
/// Three nodes conclude the curve, matching `stopCurvedPathCreationMode`.
@objc(HorosCurvedMPRPathSession)
public final class CurvedMPRPathSession: NSObject {
    private static let nodeSpacingThreshold = 1e-10
    private static let minimumNodesToComplete = 3

    private var nodes: [(Double, Double, Double)] = []

    @objc public var nodeCount: Int { nodes.count }

    @objc(addPatientNodeX:y:z:)
    public func addPatientNodeX(_ x: Double, y: Double, z: Double) -> CurvedMPRPathDecision {
        guard x.isFinite, y.isFinite, z.isFinite else {
            return CurvedMPRPathDecision(accepted: false, phase: "rejected",
                                         diagnosis: "non-finite patient node",
                                         nodeCount: nodes.count)
        }
        if let last = nodes.last {
            let dx = x - last.0, dy = y - last.1, dz = z - last.2
            if (dx * dx + dy * dy + dz * dz).squareRoot() < Self.nodeSpacingThreshold {
                return CurvedMPRPathDecision(accepted: false, phase: "rejected",
                                             diagnosis: "coincident with last node",
                                             nodeCount: nodes.count)
            }
        }
        nodes.append((x, y, z))
        return CurvedMPRPathDecision(accepted: true, phase: "drawing",
                                     diagnosis: "node added",
                                     nodeCount: nodes.count)
    }

    @objc public func complete() -> CurvedMPRPathDecision {
        if nodes.count >= Self.minimumNodesToComplete {
            return CurvedMPRPathDecision(accepted: true, phase: "complete",
                                         diagnosis: "curve concluded",
                                         nodeCount: nodes.count)
        }
        return CurvedMPRPathDecision(accepted: false, phase: "rejected",
                                     diagnosis: "need at least 3 nodes",
                                     nodeCount: nodes.count)
    }

    /// Classify a CT stack. Invalid input is named and not rewritten.
    @objc(diagnoseVolumePixelSpacingX:spacingY:slicePositions:orientationCount:)
    public static func diagnoseVolume(pixelSpacingX: Double, spacingY: Double,
                                      slicePositions: [NSNumber],
                                      orientationCount: Int) -> String {
        let zs = slicePositions.map(\.doubleValue)
        guard orientationCount == 1,
              pixelSpacingX.isFinite, spacingY.isFinite,
              pixelSpacingX > 0, spacingY > 0,
              zs.count >= 2,
              zs.allSatisfy(\.isFinite) else {
            return "invalid"
        }
        let ordered = zs.sorted()
        var intervals: [Double] = []
        intervals.reserveCapacity(ordered.count - 1)
        for index in 1..<ordered.count {
            let step = ordered[index] - ordered[index - 1]
            guard step.isFinite, step > 0 else { return "invalid" }
            intervals.append(step)
        }
        let smallest = intervals.min() ?? 0
        let largest = intervals.max() ?? 0
        if largest - smallest > max(1e-6, 0.01 * smallest) {
            return "incomplete"
        }
        let slice = intervals[0]
        if abs(pixelSpacingX - spacingY) <= 1e-6 && abs(pixelSpacingX - slice) <= 1e-6 {
            return "isotropic"
        }
        return "anisotropic"
    }

    /// Display-to-world length of one pixel. Zero means VTK has no viewport yet.
    @objc(diagnoseViewportWorldLength:)
    public static func diagnoseViewportWorldLength(_ length: Double) -> String {
        if length.isNaN { return "not a number" }
        if length < 0.00001 { return "no viewport yet" }
        if length > 1000 { return "out of range" }
        return "ready"
    }
}

/// The arithmetic of the Curved MPR's Path Assistant and of its path
/// simplification slider, apart from the window that runs them.
enum CurvedMPRPathAssistant {
    /// The path the assistant builds from the centerline it traced between
    /// each pair of the user's nodes: each segment gives its points but its
    /// last, which the next segment starts from, and the last segment gives
    /// its last point too. A segment the assistant could not trace (nil or
    /// empty) gives the user's node it starts from, and the last one the
    /// user's last node: the path had the node of an old or empty centerline,
    /// the volume's origin, there.
    static func assembledPath<Point>(segments: [[Point]?], userNodes: [Point]) -> [Point] {
        var path: [Point] = []
        for (index, segment) in segments.enumerated() {
            if let segment = segment, segment.isEmpty == false {
                path.append(contentsOf: segment.dropLast())
            } else if index < userNodes.count {
                path.append(userNodes[index])
            }
        }
        if let last = segments.last, let segment = last, let end = segment.last {
            path.append(end)
        } else if let end = userNodes.last {
            path.append(end)
        }
        return path
    }

    /// The index of the node whose removal costs least, the first of equal
    /// ones; nil when no cost is below the greatest finite float, as the two
    /// ends' are not and NaN never is. The index started at 0 then, and the
    /// first node went.
    static func cheapestRemovableNode(costs: [Float]) -> Int? {
        var index: Int? = nil
        var cost = Float.greatestFiniteMagnitude
        for (i, value) in costs.enumerated() where cost > value {
            index = i
            cost = value
        }
        return index
    }

    /// The node count the simplification slider asks for: from 3 nodes at 0 %
    /// to one per centerline point at 100 %. Counted signed, so that a
    /// centerline of fewer than 3 points does not wrap to 2^64 - 3.
    static func simplificationTarget(centerlineCount: Int, sliderPercent: Float) -> Int {
        let target = Float(centerlineCount - 3) * sliderPercent / 100 + 3
        if target.isNaN { return 0 }
        if target >= Float(Int32.max) { return Int(Int32.max) }
        if target <= Float(Int32.min) { return Int(Int32.min) }
        return Int(Int32(target))
    }

    /// Removes or restores nodes one at a time until there are `target`, and
    /// stops when a step changes nothing: no node could go, or no removal is
    /// left to undo. The loop went on forever then.
    static func simplify(toward target: Int, nodeCount: () -> Int, removeNode: () -> Void, restoreNode: () -> Void) {
        while true {
            let count = nodeCount()
            if count == target {
                return
            }
            if target < count {
                removeNode()
            } else {
                restoreNode()
            }
            if nodeCount() == count {
                return
            }
        }
    }
}
