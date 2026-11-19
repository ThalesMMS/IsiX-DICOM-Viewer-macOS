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

/// Why a segment of the path assistant has no nodes.
public enum VesselPathFailure: Sendable, Equatable {
    /// The vessel tracer refused the segment: the same point twice, a point
    /// that is not a number, a volume without voxels or voxel sizes.
    case refused(VesselTraceError)
    /// The former fly-through assistant found no path between the points.
    case noPath
    /// The former assistant could not allocate its distance map.
    case outOfMemory
}

/// What the path assistant made of one segment of a curved path, from one
/// node to the next.
public enum VesselPathSegment: Sendable, Equatable {
    /// Traced by the vessel tracer: the nodes of its curve, in input
    /// coordinates, from the first point to the second; the longest stretch
    /// of the path out of the lumen, in millimetres; and whether the lumen
    /// hardly stands out from the tissue it lies on.
    case traced(nodes: [SIMD3<Float>], longestGap: Float, isLumenFaint: Bool)
    /// An air-filled lumen (an airway, a colon), traced by the former
    /// fly-through assistant: its centerline thinned by the lumen's radius.
    case formerAssistant(nodes: [SIMD3<Float>])
    /// No path.
    case failed(VesselPathFailure)

    /// The segment's nodes, nil when it has none.
    public var nodes: [SIMD3<Float>]? {
        switch self {
        case .traced(let nodes, _, _), .formerAssistant(let nodes): nodes.isEmpty ? nil : nodes
        case .failed: nil
        }
    }
}

/// The path assistant's segments through the nodes of a curved path, and
/// what the user should be told of them.
public struct VesselAssistedPath: Sendable, Equatable {
    public let segments: [VesselPathSegment]

    public init(segments: [VesselPathSegment]) {
        self.segments = segments
    }

    /// Each segment's nodes, nil for a segment without: what the curved path
    /// is assembled from.
    public var segmentNodes: [[SIMD3<Float>]?] { segments.map(\.nodes) }

    /// The longest stretch out of the lumen of the traced segments, in
    /// millimetres: an occlusion, or two points on different vessels.
    public var longestGap: Float {
        segments.reduce(0) { longest, segment in
            if case .traced(_, let gap, _) = segment { return max(longest, gap) }
            return longest
        }
    }

    /// Whether a traced segment's lumen hardly stands out from the tissue
    /// round it, where the path may leave the vessel.
    public var isLumenFaint: Bool {
        segments.contains { if case .traced(_, _, true) = $0 { true } else { false } }
    }

    /// Why the segments without nodes have none, in their order.
    public var failures: [VesselPathFailure] {
        segments.compactMap { if case .failed(let failure) = $0 { failure } else { nil } }
    }

    /// Whether the path needs checking: a stretch out of the lumen longer
    /// than `VesselPathAssistant.noticeGapMillimetres`, or a faint lumen.
    public var needsChecking: Bool {
        longestGap > VesselPathAssistant.noticeGapMillimetres || isLumenFaint
    }
}

/// The Curved MPR's path assistant: the vessel tracer between each node of a
/// curved path and the next, off the caller's actor, with the former
/// fly-through assistant for an air-filled lumen only, which the tracer
/// leaves to it. The former assistant is built for the first such segment of
/// a trace and goes with it: the window no longer keeps its distance map,
/// about 120 MB for a volume of 256 × 256 × 450, from the moment it opens.
public enum VesselPathAssistant {
    /// A stretch out of the lumen longer than this is worth telling the user
    /// of: a few voxels at a tight or calcified spot are not.
    public static let noticeGapMillimetres: Float = 2

    /// The segments between each node and the next, input coordinates.
    /// `progress` hears the share of the tracer's work done (0 to 1), on the
    /// trace's thread. Cancelling the task ends the trace with `.cancelled`
    /// within milliseconds; the former assistant cannot stop half way, and a
    /// cancel during one of its segments ends the trace after it.
    @concurrent
    public static func trace(through nodes: [SIMD3<Float>], in volume: VesselVolume,
                             options: VesselTraceOptions = VesselTraceOptions(),
                             progress: @escaping @Sendable (Double) -> Void = { _ in })
        async throws(VesselTraceError) -> VesselAssistedPath {
        let traced = try await VesselTracer.traceSegments(through: nodes, in: volume, options: options, progress: progress)
        var former: FlyPathAssistant?
        var formerBuilt = false
        var segments: [VesselPathSegment] = []
        for (index, result) in traced.enumerated() {
            switch result {
            case .success(let line):
                segments.append(.traced(nodes: line.curveNodes(), longestGap: line.longestGap, isLumenFaint: line.isLumenFaint))
            case .failure(.darkLumen):
                if Task.isCancelled { throw .cancelled }
                if !formerBuilt {
                    former = formerAssistant(over: volume)
                    formerBuilt = true
                }
                segments.append(withExtendedLifetime(volume) { formerSegment(from: nodes[index], to: nodes[index + 1], with: former) })
            case .failure(let error):
                segments.append(.failed(.refused(error)))
            }
        }
        if Task.isCancelled { throw .cancelled }
        return VesselAssistedPath(segments: segments)
    }

    /// The former assistant over `volume`, resampled as the Curved MPR
    /// resampled it, with its step of 3 for a smoothed line; nil without the
    /// memory for its distance map.
    static func formerAssistant(over volume: VesselVolume) -> FlyPathAssistant? {
        let assistant = FlyPathAssistant(volume: volume.voxels, width: volume.width, height: volume.height, depth: volume.depth,
                                         spacing: volume.spacing, resampleVoxelSize: formerResampleVoxelSize(of: volume))
        assistant?.centerlineResampleStepLength = 3
        return assistant
    }

    /// The resampled voxel the Curved MPR gave the former assistant: the
    /// input's own width across a matrix of 256 or less, else the wider
    /// field of view over 256.
    static func formerResampleVoxelSize(of volume: VesselVolume) -> Float {
        guard volume.width > 256 || volume.height > 256 else { return volume.spacing.x }
        let across = volume.spacing.x * Float(volume.width), down = volume.spacing.y * Float(volume.height)
        return Float(Double(across > down ? across : down) / 256)
    }

    /// The former assistant's segment from `a` to `b`, thinned by the lumen's
    /// radius as the window thinned it. A distance transform that did not
    /// finish is asked again, five more times, as the window asked it.
    static func formerSegment(from a: SIMD3<Float>, to b: SIMD3<Float>, with assistant: FlyPathAssistant?) -> VesselPathSegment {
        guard let assistant else { return .failed(.outOfMemory) }
        var (code, points) = assistant.centerline(from: a, to: b)
        var retries = 0
        while code == FlyPathAssistant.distanceTransformNotFinished && retries < 5 {
            (code, points) = assistant.centerline(from: a, to: b)
            retries += 1
        }
        if code == FlyPathAssistant.noEnoughMemory { return .failed(.outOfMemory) }
        guard code == 0, !points.isEmpty else { return .failed(.noPath) }
        return .formerAssistant(nodes: assistant.thinnedCenterlineIndices(points).map { points[$0] })
    }
}

/// When the Curved MPR's Vessel Analysis runs the path assistant on its own:
/// as soon as an edit leaves the path with two nodes, the two points marked,
/// that it has not traced yet. The edits after a trace (a node dragged or
/// added to the traced path, the transverse sections moved) do not trace
/// again; two new points do, after the path was deleted or undone, and so do
/// the two points of a trace that found nothing once one of them is moved.
/// The traced path thinned back to its two ends is not traced again: its ends
/// come back through the volume's single-precision voxels, a few
/// hundred-thousandths of a millimetre from the points marked.
public struct VesselAnalysisTrigger: Sendable, Equatable {
    /// How near a point stays the point traced, in the nodes' unit (millimetres).
    public static let samePointTolerance = 0.01
    private var lastTraced: [SIMD3<Double>]?

    public init() {}

    /// Whether the path, as an edit leaves `nodes`, is to be traced now.
    public mutating func shouldTrace(nodes: [SIMD3<Double>]) -> Bool {
        guard nodes.count == 2 else { return false }
        if let lastTraced, zip(nodes, lastTraced).allSatisfy({ (($0 - $1) * ($0 - $1)).sum() <= Self.samePointTolerance * Self.samePointTolerance }) {
            return false
        }
        lastTraced = nodes
        return true
    }
}
