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
import simd

/// The brush ROIs of a 2D viewer across its reslices.
///
/// The orientation matrix replaces the viewer's slices by a reslice of the
/// volume, then flips or rotates them: the ROI lists start empty, and the
/// brushes, which are pixel textures of the old slices, were lost until the
/// series was opened again. Before the reslice the viewer's brushes are taken
/// with the geometry of their slices; after it, every brush is resampled on the
/// new slices (BrushResample) and added as brush ROIs with the same name,
/// colour, opacity, visibility, lock, group and comment.
///
/// The new slices are generated, so these ROIs are never saved over the
/// original images' ROIs. The brushes taken from the original slices stay
/// the source of the next reslices while they are left as they were, so
/// going back and forth does not resample a resample; a brush drawn, edited,
/// renamed or deleted on the resliced slices makes the current ones the source.
/// The source belongs to the series on screen and goes with it.
@MainActor
@objc(HorosBrushReslice)
public final class BrushReslice: NSObject {

    /// What a resampled brush keeps of its source.
    struct Appearance {
        var name: String
        var color: RGBColor
        var opacity: Float
        var hidden: Bool
        var locked: Bool
        var selectable: Bool
        var groupID: TimeInterval
        var comments: String?
        var thickness: Float
        var displayTextualData: Bool
        var textNameOnly: Bool

        init(_ roi: ROI) {
            name = roi.name ?? ""
            color = roi.rgbcolor
            opacity = roi.opacity
            hidden = roi.hidden
            locked = roi.locked
            selectable = roi.selectable
            groupID = roi.groupID
            comments = roi.comments
            thickness = roi.thickness
            displayTextualData = roi.displayTextualData
            textNameOnly = roi.textNameOnly
        }

        /// The brushes of one slice that are one mask: same name, group and colour.
        func isSameMask(as other: Appearance) -> Bool {
            name == other.name && groupID == other.groupID &&
                color.red == other.color.red && color.green == other.color.green && color.blue == other.color.blue
        }

        /// Not `globally`: the colour, opacity and thickness of the brushes
        /// drawn next stay the user's.
        func apply(to roi: ROI) {
            roi.setColor(color, globally: false)
            roi.setOpacity(opacity, globally: false)
            roi.setThickness(thickness, globally: false)
            roi.hidden = hidden
            roi.locked = locked
            roi.selectable = selectable
            roi.groupID = groupID
            roi.comments = comments
            roi.displayTextualData = displayTextualData
            roi.textNameOnly = textNameOnly
        }
    }

    struct Mask {
        var appearance: Appearance
        var planes: [BrushResample.Plane?]
    }

    struct Phase {
        var stack: BrushResample.Stack
        var masks: [Mask]
    }

    /// One entry per movie index; nil where the phase has no brush.
    private let phases: [Phase?]

    private init(phases: [Phase?]) {
        self.phases = phases
    }

    /// What the viewer keeps between reslices: the source and the ROIs made
    /// from it, with what they were when made.
    private final class Record: NSObject {
        let source: BrushReslice
        let made: [(roi: ROI, signature: Int)]
        /// Set while the brushes are being resampled for the slices on screen
        /// (`applyLater`): they are not on the viewer yet.
        let pending: Int?
        init(source: BrushReslice, made: [(roi: ROI, signature: Int)], pending: Int? = nil) {
            self.source = source
            self.made = made
            self.pending = pending
        }
    }

    private static var nextTicket = 0

    private static var recordKey: UInt8 = 0

    private static func record(of viewer: ViewerController) -> Record? {
        objc_getAssociatedObject(viewer, &recordKey) as? Record
    }

    /// The viewer's series goes: so does the source of its brushes.
    @objc(forgetViewer:)
    public static func forget(_ viewer: ViewerController) {
        objc_setAssociatedObject(viewer, &recordKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    // MARK: Taking

    /// The viewer's brushes before a reslice, or nil when it has none.
    @objc(captureFromViewer:)
    public static func capture(from viewer: ViewerController) -> BrushReslice? {
        let phaseCount = max(Int(viewer.horos_maxMovieIndex), 1)
        var current: [(roi: ROI, signature: Int)] = []
        for movie in 0..<phaseCount {
            for case let slice as NSArray in viewer.horos_roiList(at: movie) ?? NSMutableArray() {
                for case let roi as ROI in slice where isBrush(roi) { current.append((roi, signature(of: roi))) }
            }
        }
        // Still being resampled for these slices: the source has them all.
        if let record = record(of: viewer), record.pending != nil { return record.source }
        guard !current.isEmpty else { return nil }

        // Left as they were made: the source they came from is the better one.
        if let record = record(of: viewer), record.made.count == current.count {
            let made = Dictionary(record.made.map { (ObjectIdentifier($0.roi), $0.signature) }, uniquingKeysWith: { a, _ in a })
            if current.allSatisfy({ made[ObjectIdentifier($0.roi)] == $0.signature }) { return record.source }
        }

        var phases: [Phase?] = []
        for movie in 0..<phaseCount {
            phases.append(phase(pixList: viewer.horos_pixList(at: movie), roiList: viewer.horos_roiList(at: movie)))
        }
        return BrushReslice(phases: phases)
    }

    private static func isBrush(_ roi: ROI) -> Bool {
        roi.type == .tPlain && roi.textureBuffer != nil && roi.textureWidth > 0 && roi.textureHeight > 0
    }

    static func slice(of pix: DCMPix) -> BrushResample.Slice {
        var o = [Double](repeating: 0, count: 9)
        pix.orientationDouble(&o)
        return BrushResample.Slice(origin: SIMD3(pix.originX, pix.originY, pix.originZ),
                                   row: SIMD3(o[0], o[1], o[2]), column: SIMD3(o[3], o[4], o[5]),
                                   spacingX: pix.pixelSpacingX, spacingY: pix.pixelSpacingY,
                                   width: pix.pwidth, height: pix.pheight)
    }

    private static func phase(pixList: NSMutableArray?, roiList: NSMutableArray?) -> Phase? {
        guard let pixList, let roiList else { return nil }
        let pixes = pixList.compactMap { $0 as? DCMPix }
        guard pixes.count == pixList.count, let stack = BrushResample.Stack(pixes.map(slice(of:))) else { return nil }
        var masks: [Mask] = []
        for (index, entry) in roiList.enumerated() where index < pixes.count {
            guard let rois = entry as? NSArray else { continue }
            for case let roi as ROI in rois where isBrush(roi) {
                let appearance = Appearance(roi)
                let plane = BrushResample.Plane(x: Int(roi.textureUpLeftCornerX), y: Int(roi.textureUpLeftCornerY),
                                                width: Int(roi.textureWidth), height: Int(roi.textureHeight),
                                                bytes: Array(UnsafeBufferPointer(start: roi.textureBuffer,
                                                                                 count: Int(roi.textureWidth) * Int(roi.textureHeight))))
                let m = masks.firstIndex { $0.appearance.isSameMask(as: appearance) } ?? {
                    masks.append(Mask(appearance: appearance, planes: Array(repeating: nil, count: pixes.count)))
                    return masks.count - 1
                }()
                // Two brushes of one mask on a slice are one plane: their union.
                masks[m].planes[index] = masks[m].planes[index].map { union($0, plane) } ?? plane
            }
        }
        return masks.isEmpty ? nil : Phase(stack: stack, masks: masks)
    }

    private static func union(_ a: BrushResample.Plane, _ b: BrushResample.Plane) -> BrushResample.Plane {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        let x1 = max(a.x + a.width, b.x + b.width), y1 = max(a.y + a.height, b.y + b.height)
        var out = BrushResample.Plane(x: x0, y: y0, width: x1 - x0, height: y1 - y0,
                                      bytes: Array(repeating: 0, count: (x1 - x0) * (y1 - y0)))
        for v in 0..<out.height {
            for u in 0..<out.width where a.contains(x0 + u, y0 + v) || b.contains(x0 + u, y0 + v) {
                out.bytes[v * out.width + u] = 255
            }
        }
        return out
    }

    /// What a brush is: its pixels, where, and how it looks.
    private static func signature(of roi: ROI) -> Int {
        var hasher = Hasher()
        hasher.combine(roi.textureUpLeftCornerX)
        hasher.combine(roi.textureUpLeftCornerY)
        hasher.combine(roi.textureWidth)
        hasher.combine(roi.textureHeight)
        if let buffer = roi.textureBuffer {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: buffer, count: Int(roi.textureWidth) * Int(roi.textureHeight)))
        }
        let appearance = Appearance(roi)
        hasher.combine(appearance.name)
        hasher.combine(appearance.color.red)
        hasher.combine(appearance.color.green)
        hasher.combine(appearance.color.blue)
        hasher.combine(appearance.opacity)
        hasher.combine(appearance.hidden)
        hasher.combine(appearance.locked)
        hasher.combine(appearance.selectable)
        hasher.combine(appearance.groupID)
        hasher.combine(appearance.comments)
        return hasher.finalize()
    }

    // MARK: Giving back

    /// The masks of one phase still to be placed on the viewer's new slices.
    private struct Job {
        var movie: Int
        var pixList: NSMutableArray
        var masks: [Mask]
        var stack: BrushResample.Stack
        var planes: [[BrushResample.Plane?]]
        var target: [BrushResample.Slice]
    }

    /// What `apply` does on the viewer's new slices: a mask they already
    /// have is left alone.
    private func jobs(for viewer: ViewerController) -> [Job] {
        var jobs: [Job] = []
        let phaseCount = min(max(Int(viewer.horos_maxMovieIndex), 1), phases.count)
        for movie in 0..<phaseCount {
            guard let phase = phases[movie],
                  let pixList = viewer.horos_pixList(at: movie), let roiList = viewer.horos_roiList(at: movie) else { continue }
            let pixes = pixList.compactMap { $0 as? DCMPix }
            guard pixes.count == pixList.count, roiList.count == pixes.count else { continue }
            var present: [Appearance] = []
            for case let slice as NSArray in roiList {
                for case let roi as ROI in slice where Self.isBrush(roi) { present.append(Appearance(roi)) }
            }
            let masks = phase.masks.filter { mask in !present.contains { $0.isSameMask(as: mask.appearance) } }
            jobs.append(Job(movie: movie, pixList: pixList, masks: masks, stack: phase.stack,
                            planes: masks.map(\.planes), target: pixes.map(Self.slice(of:))))
        }
        return jobs
    }

    /// The masks are independent: resampled side by side.
    nonisolated private static func resample(_ planes: [[BrushResample.Plane?]], from stack: BrushResample.Stack,
                                             to target: [BrushResample.Slice]) -> [[BrushResample.Plane?]] {
        let results = Results(count: planes.count)
        DispatchQueue.concurrentPerform(iterations: planes.count) { m in
            results.set(m, BrushResample.resample(planes[m], from: stack, to: target))
        }
        return (0..<planes.count).map { results.get($0) }
    }

    /// The resampled masks as brush ROIs on the viewer's slices, while they
    /// are still the slices the masks were resampled for.
    private func place(_ jobs: [Job], _ results: [[[BrushResample.Plane?]]], on viewer: ViewerController) {
        var made: [(roi: ROI, signature: Int)] = []
        for (job, planes) in zip(jobs, results) {
            guard viewer.horos_pixList(at: job.movie) === job.pixList, let roiList = viewer.horos_roiList(at: job.movie) else { continue }
            let pixes = job.pixList.compactMap { $0 as? DCMPix }
            guard pixes.count == roiList.count else { continue }
            for (m, mask) in job.masks.enumerated() {
                for (index, plane) in planes[m].enumerated() {
                    guard let plane, index < pixes.count, let slice = roiList[index] as? NSMutableArray else { continue }
                    let pix = pixes[index]
                    var bytes = plane.bytes
                    let made1 = bytes.withUnsafeMutableBufferPointer { buffer in
                        ROI(texture: buffer.baseAddress, textWidth: Int32(plane.width), textHeight: Int32(plane.height),
                            textName: mask.appearance.name, positionX: Int32(plane.x), positionY: Int32(plane.y),
                            spacingX: Float(pix.pixelSpacingX), spacingY: Float(pix.pixelSpacingY),
                            imageOrigin: NSPoint(x: pix.originX, y: pix.originY))
                    }
                    guard let roi = made1 else { continue }
                    mask.appearance.apply(to: roi)
                    slice.add(roi)
                    viewer.horos_imageView?.roiSet(roi)
                    made.append((roi, Self.signature(of: roi)))
                }
            }
        }
        if made.isEmpty {
            Self.forget(viewer)
            return
        }
        objc_setAssociatedObject(viewer, &Self.recordKey, Record(source: self, made: made), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        NotificationCenter.default.post(name: .OsirixROIChange, object: nil, userInfo: nil)
        viewer.horos_imageView?.needsDisplay = true
    }

    /// After the reslice, flips and rotations: the brushes on the viewer's new
    /// slices, before this returns. A new viewer gets them so.
    @objc(applyToViewer:)
    public func apply(to viewer: ViewerController) {
        let jobs = jobs(for: viewer)
        place(jobs, jobs.map { Self.resample($0.planes, from: $0.stack, to: $0.target) }, on: viewer)
    }

    /// The same for the viewer's own slices, resampled off the main thread:
    /// thousands of brushes took half a second there at each plane change.
    /// They appear once resampled, if the viewer still shows those slices;
    /// meanwhile a new reslice takes them from this source.
    @objc(applyLaterToViewer:)
    public func applyLater(to viewer: ViewerController) {
        let jobs = jobs(for: viewer)
        guard jobs.contains(where: { !$0.masks.isEmpty }) else {
            place(jobs, jobs.map { $0.masks.map { _ in [] } }, on: viewer)
            return
        }
        Self.nextTicket += 1
        let ticket = Self.nextTicket
        objc_setAssociatedObject(viewer, &Self.recordKey, Record(source: self, made: [], pending: ticket), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let work = jobs.map { ($0.planes, $0.stack, $0.target) }
        let pending = Pending(viewer: viewer, jobs: jobs)
        DispatchQueue.global(qos: .userInitiated).async {
            let results = work.map { Self.resample($0.0, from: $0.1, to: $0.2) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let viewer = pending.viewer, Self.record(of: viewer)?.pending == ticket else { return }
                    self.place(pending.jobs, results, on: viewer)
                }
            }
        }
    }

    /// The viewer and its jobs, carried to the main thread and read only there.
    private final class Pending: @unchecked Sendable {
        weak var viewer: ViewerController?
        let jobs: [Job]
        init(viewer: ViewerController, jobs: [Job]) {
            self.viewer = viewer
            self.jobs = jobs
        }
    }

    /// The masks' planes, written from the resampling threads, each slot once.
    private final class Results: @unchecked Sendable {
        private var planes: [[BrushResample.Plane?]]
        private let lock = NSLock()
        init(count: Int) { planes = Array(repeating: [], count: count) }
        func set(_ index: Int, _ value: [BrushResample.Plane?]) { lock.withLock { planes[index] = value } }
        func get(_ index: Int) -> [BrushResample.Plane?] { lock.withLock { planes[index] } }
    }
}
