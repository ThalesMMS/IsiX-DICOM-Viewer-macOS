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

import Cocoa
import Accelerate

/// Given a volume, generates its projection through the Z (depth) direction.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/CPRProjectionOperation.h>, which keeps the CPRProjectionMode enum,
/// are those of the former class.
///
/// The application's curved and oblique operations no longer queue it: they
/// fold their slab plane by plane with `CPRSlabFold` through
/// `CPRSlabProjector`. The class stays for the plugins built against the
/// former SDK, and projects with the same fold.
///
/// @unchecked Sendable, restated from Operation: the caller sets
/// `volumeData` and `projectionMode` before it queues the operation and not
/// after; `generatedVolume` is written by `main()` and read once the
/// operation has finished.
@objc(CPRProjectionOperation)
public final class CPRProjectionOperation: Operation, @unchecked Sendable {
    @objc public var volumeData: CPRVolumeData?
    @objc public private(set) var generatedVolume: CPRVolumeData?
    @objc public var projectionMode: CPRProjectionMode

    public override init() {
        projectionMode = CPRProjectionMode(CPRProjectionModeNone.rawValue)
        super.init()
    }

    public override func main() {
        autoreleasepool {
            self.project()
        }
    }

    private func project() {
        if isCancelled {
            return
        }

        if projectionMode == CPRProjectionMode(CPRProjectionModeNone.rawValue) {
            generatedVolume = volumeData
            return
        }

        // A nil volume behaves as a message to nil did: zero sizes, no data.
        let pixelsWide = volumeData?.pixelsWide ?? 0
        let pixelsHigh = volumeData?.pixelsHigh ?? 0
        let pixelsDeep = volumeData?.pixelsDeep ?? 0
        let pixelsPerPlane = Int(pixelsWide) &* Int(pixelsHigh)
        let floatBytes = malloc(MemoryLayout<Float>.size &* pixelsPerPlane)!.assumingMemoryBound(to: Float.self)

        var inlineBuffer = CPRVolumeDataInlineBuffer()
        if volumeData?.aquireInlineBuffer(&inlineBuffer) ?? false {
            let planes = CPRVolumeDataFloatBytes(&inlineBuffer)
            memcpy(floatBytes, planes, MemoryLayout<Float>.size &* pixelsPerPlane)
            if CPRSlabFold.foldsEveryPlane(projectionMode) {
                var i = 1
                while UInt(i) < UInt(pixelsDeep) {
                    if isCancelled {
                        break
                    }
                    CPRSlabFold.fold(planes! + i &* pixelsPerPlane, index: i, into: floatBytes, count: pixelsPerPlane, mode: projectionMode)
                    i += 1
                }
            }
        } else {
            // A volume whose data is gone projects to zeros, as a failed fill
            // does: the output was returned with the malloc'd bytes as they
            // were.
            memset(floatBytes, 0, MemoryLayout<Float>.size &* pixelsPerPlane)
        }
        volumeData?.releaseInlineBuffer(&inlineBuffer)

        let volumeTransform = N3AffineTransformConcat(volumeData?.volumeTransform ?? N3AffineTransform(),
                                                      N3AffineTransformMakeScale(1.0, 1.0, 1.0 / CGFloat(pixelsDeep)))
        generatedVolume = CPRVolumeData(floatBytesNoCopy: floatBytes, pixelsWide: numericCast(pixelsWide), pixelsHigh: numericCast(pixelsHigh), pixelsDeep: 1,
                                        volumeTransform: volumeTransform, outOfBoundsValue: volumeData?.outOfBoundsValue ?? 0, freeWhenDone: true)
    }
}

/// The projection of a slab through its depth, one plane after the other.
enum CPRSlabFold {
    /// Whether `mode` folds every plane of a slab into its projection.
    /// CPRProjectionModeVR, which was never implemented, and any value
    /// CPRProjectionMode does not name project to the first plane alone, and
    /// CPRProjectionModeNone keeps the slab as it is.
    static func foldsEveryPlane(_ mode: CPRProjectionMode) -> Bool {
        return mode == CPRProjectionMode(CPRProjectionModeMIP.rawValue) || mode == CPRProjectionMode(CPRProjectionModeMinIP.rawValue)
            || mode == CPRProjectionMode(CPRProjectionModeMean.rawValue)
    }

    /// Folds plane `index` (1 and up) of a slab into `projection`, which holds
    /// the projection of the planes before it, the first plane as it was to
    /// begin with: the larger value, the smaller one, or the running mean, which
    /// vDSP_vavlin weighs by the `index` planes already in it. Folded in the
    /// order of their depth, the planes give the same bits whether the whole
    /// slab is in memory or only a few of its planes at a time.
    static func fold(_ plane: UnsafePointer<Float>, index: Int, into projection: UnsafeMutablePointer<Float>, count: Int,
                     mode: CPRProjectionMode) {
        let length = vDSP_Length(count)
        switch mode {
        case CPRProjectionMode(CPRProjectionModeMIP.rawValue):
            vDSP_vmax(projection, 1, plane, 1, projection, 1, length)
        case CPRProjectionMode(CPRProjectionModeMinIP.rawValue):
            vDSP_vmin(projection, 1, plane, 1, projection, 1, length)
        case CPRProjectionMode(CPRProjectionModeMean.rawValue):
            var weight = Float(index)
            vDSP_vavlin(plane, 1, &weight, projection, 1, length)
        default:
            break
        }
    }
}

/// Samples a slab with CPRHorizontalFillOperations and projects it while its
/// planes arrive, so that the memory a projection takes no longer grows with
/// the depth of the slab: the straightened, stretched and oblique CPR
/// operations sampled every plane of the slab into one volume before
/// projecting it, which at the thick end of the slab slider (the whole
/// volume) asked for gigabytes.
///
/// The planes are sampled in the order of their depth, a window of them at a
/// time. When every fill of the oldest plane of the window has finished, that
/// plane is folded into the projection (CPRSlabFold, in the order of the
/// planes, as CPRProjectionOperation folds a whole volume) and the next plane
/// is sampled in its place, so the fills keep every processor busy without a
/// pause between groups of planes. CPRProjectionModeNone asks for the slab
/// itself: the window then holds every plane and becomes the result.
/// CPRProjectionModeVR and the values CPRProjectionMode does not name project
/// to the first plane, the only one sampled.
///
/// @unchecked Sendable: the fill operations report to it from their threads
/// and `cancel()` may come from any thread; every mutable member is read and
/// written under `lock`. The fills of a plane write its floats before they
/// report, and the plane is folded under the lock after the last of them has
/// reported, so the fold reads every float they wrote, and a slot of the
/// window is given to the next plane only after the fold.
final class CPRSlabProjector: @unchecked Sendable {
    /// The fill operations that sample `plane` (0 is the near side of the slab)
    /// into `floatBytes`, pixelsWide * pixelsHigh floats.
    typealias PlaneFills = @Sendable (_ plane: Int, _ floatBytes: UnsafeMutablePointer<Float>) -> [Operation]
    typealias Completion = @Sendable (_ volume: CPRVolumeData?) -> Void

    /// The window holds no more than this, unless four planes need more.
    private static let windowByteBudget = 64 << 20

    private let lock = NSLock()
    private let projectionMode: CPRProjectionMode
    private let pixelsWide: Int
    private let pixelsHigh: Int
    private let pixelsDeep: Int
    private let pixelsPerPlane: Int
    /// The slab's transform from patient space to its pixels.
    private let volumeTransform: N3AffineTransform
    private let outOfBoundsValue: Float
    /// Every plane of the slab, or the first one alone.
    private let sampledPlanes: Int
    private let windowPlanes: Int
    private var window: UnsafeMutablePointer<Float>?
    /// The projection of the planes folded so far; nil when the slab itself is
    /// the result.
    private var projection: UnsafeMutablePointer<Float>?
    /// The fills of each slot of the window that have not finished.
    private var pendingFills: [Int]
    private var runningFills: [ObjectIdentifier: Operation] = [:]
    private var queuedPlanes = 0
    private var foldedPlanes = 0
    private var started = false
    private var cancelled = false
    private var ended = false
    /// Whether the projection ended with every plane folded, decided when it
    /// ended: a cancel that comes later does not take the volume back.
    private var projected = false
    private var queue: OperationQueue?
    private var planeFills: PlaneFills?
    private var completion: Completion?
    /// Told, under the projector's lock, how many fills are queued or running
    /// each time that number changes, for the operation that keeps it where
    /// its class declared a count. Set before `start`; let go of, like
    /// `completion`, when the projection ends.
    var outstandingFillsChanged: (@Sendable (_ fills: Int) -> Void)?

    /// Nil when the memory cannot be had (or its size overflows), as the
    /// operations' allocation of the whole slab failed before.
    init?(projectionMode: CPRProjectionMode, pixelsWide: Int, pixelsHigh: Int, pixelsDeep: Int, fillHeight: Int,
          volumeTransform: N3AffineTransform, outOfBoundsValue: Float) {
        let pixelsPerPlane = pixelsWide.multipliedReportingOverflow(by: pixelsHigh)
        guard pixelsWide >= 0, pixelsHigh >= 0, pixelsDeep >= 1, !pixelsPerPlane.overflow else {
            return nil
        }
        let keepsSlab = projectionMode == CPRProjectionMode(CPRProjectionModeNone.rawValue)
        self.projectionMode = projectionMode
        self.pixelsWide = pixelsWide
        self.pixelsHigh = pixelsHigh
        self.pixelsDeep = pixelsDeep
        self.pixelsPerPlane = pixelsPerPlane.partialValue
        self.volumeTransform = volumeTransform
        self.outOfBoundsValue = outOfBoundsValue
        sampledPlanes = keepsSlab || CPRSlabFold.foldsEveryPlane(projectionMode) ? pixelsDeep : 1
        windowPlanes = keepsSlab ? pixelsDeep : Self.windowPlanes(sampledPlanes: sampledPlanes, pixelsWide: pixelsWide,
                                                                   pixelsHigh: pixelsHigh, fillHeight: fillHeight)
        pendingFills = [Int](repeating: 0, count: windowPlanes)

        let planeBytes = self.pixelsPerPlane.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        let windowBytes = planeBytes.partialValue.multipliedReportingOverflow(by: windowPlanes)
        guard !planeBytes.overflow, !windowBytes.overflow else {
            return nil
        }
        window = malloc(windowBytes.partialValue)?.assumingMemoryBound(to: Float.self)
        projection = keepsSlab ? nil : malloc(planeBytes.partialValue)?.assumingMemoryBound(to: Float.self)
        guard window != nil, keepsSlab || projection != nil else {
            return nil
        }
    }

    deinit {
        free(window)
        free(projection)
    }

    /// The planes in memory at once: four fills per processor, so that the
    /// processors are never short of work, in a multiple of four planes, so
    /// that each plane sits at the alignment it would have in the whole slab;
    /// no more than the byte budget unless four planes need more, and no more
    /// than the slab.
    static func windowPlanes(sampledPlanes: Int, pixelsWide: Int, pixelsHigh: Int, fillHeight: Int) -> Int {
        let fillsPerPlane = max(1, (pixelsHigh + max(fillHeight, 1) - 1) / max(fillHeight, 1))
        let fills = 4 * max(ProcessInfo.processInfo.activeProcessorCount, 1)
        let planeBytes = max(1, pixelsWide.multipliedReportingOverflow(by: pixelsHigh &* MemoryLayout<Float>.size).partialValue)
        let busy = (fills + fillsPerPlane - 1) / fillsPerPlane
        let planes = max(4, min((busy + 3) / 4 * 4, windowByteBudget / planeBytes / 4 * 4))
        return max(1, min(planes, sampledPlanes))
    }

    /// Samples the slab on `queue`, and calls `completion` once, on the thread
    /// of the fill that finished last, with the projection, or nil when the
    /// projector is cancelled. `planeFills` is called under the projector's
    /// lock and is let go of, like `completion`, when the projection ends.
    func start(on queue: OperationQueue, planeFills: @escaping PlaneFills, completion: @escaping Completion) {
        lock.lock()
        precondition(!started, "a slab projector runs once")
        started = true
        self.queue = queue
        self.planeFills = planeFills
        self.completion = completion
        var fills: [Operation] = []
        let ending: Bool
        if cancelled {
            ending = !ended
            ended = true
        } else {
            (fills, ending) = advanceLocked()
        }
        outstandingFillsChanged?(runningFills.count)
        lock.unlock()

        queue.addOperations(fills, waitUntilFinished: false)
        if ending {
            end()
        }
    }

    /// Cancels the fills that run; the projection then ends without a volume.
    func cancel() {
        lock.lock()
        cancelled = true
        let fills = Array(runningFills.values)
        lock.unlock()
        for fill in fills {
            fill.cancel()
        }
    }

    private func fillFinished(_ fill: ObjectIdentifier, slot: Int) {
        lock.lock()
        runningFills[fill] = nil
        pendingFills[slot] -= 1
        var fills: [Operation] = []
        var ending = false
        if cancelled {
            if runningFills.isEmpty && !ended {
                ended = true
                ending = true
            }
        } else {
            (fills, ending) = advanceLocked()
        }
        outstandingFillsChanged?(runningFills.count)
        let queue = self.queue
        lock.unlock()

        queue?.addOperations(fills, waitUntilFinished: false)
        if ending {
            end()
        }
    }

    /// Under the lock: folds the planes whose fills have all finished, in the
    /// order of their depth, and samples the next planes into the slots they
    /// leave. Returns the fills to queue, and whether the projection is done.
    private func advanceLocked() -> ([Operation], Bool) {
        var fills: [Operation] = []
        var progressed = true
        while progressed {
            progressed = false
            while foldedPlanes < queuedPlanes && pendingFills[foldedPlanes % windowPlanes] == 0 {
                foldLocked(plane: foldedPlanes)
                foldedPlanes += 1
                progressed = true
            }
            if foldedPlanes == sampledPlanes {
                break
            }
            while queuedPlanes < sampledPlanes && queuedPlanes - foldedPlanes < windowPlanes {
                let slot = queuedPlanes % windowPlanes
                let planeFills = self.planeFills?(queuedPlanes, window! + slot &* pixelsPerPlane) ?? []
                pendingFills[slot] = planeFills.count
                for fill in planeFills {
                    let identifier = ObjectIdentifier(fill)
                    runningFills[identifier] = fill
                    fill.completionBlock = { [self] in
                        fillFinished(identifier, slot: slot)
                    }
                }
                fills += planeFills
                queuedPlanes += 1
                // A plane without fills is ready at once.
                progressed = progressed || planeFills.isEmpty
            }
        }
        let done = foldedPlanes == sampledPlanes && !ended
        if done {
            ended = true
            projected = true
        }
        return (fills, done)
    }

    /// Under the lock: plane `plane`, every fill of which has finished, into the
    /// projection; the first plane is copied, as CPRProjectionOperation does.
    private func foldLocked(plane: Int) {
        guard let projection, let window else {
            return
        }
        let floatBytes = window + (plane % windowPlanes) &* pixelsPerPlane
        if plane == 0 {
            memcpy(projection, floatBytes, MemoryLayout<Float>.size &* pixelsPerPlane)
        } else {
            CPRSlabFold.fold(floatBytes, index: plane, into: projection, count: pixelsPerPlane, mode: projectionMode)
        }
    }

    /// Once, when the last plane is folded or the last fill of a cancelled
    /// projection has finished: no fill runs any more.
    private func end() {
        lock.lock()
        let completion = self.completion
        self.completion = nil
        planeFills = nil
        outstandingFillsChanged = nil
        queue = nil
        var volume: CPRVolumeData?
        if projected {
            if let projection {
                // The slab of pixelsDeep planes projected to one, as
                // CPRProjectionOperation scales it.
                volume = CPRVolumeData(floatBytesNoCopy: projection, pixelsWide: UInt(pixelsWide), pixelsHigh: UInt(pixelsHigh), pixelsDeep: 1,
                                       volumeTransform: N3AffineTransformConcat(volumeTransform, N3AffineTransformMakeScale(1.0, 1.0, 1.0 / CGFloat(pixelsDeep))),
                                       outOfBoundsValue: outOfBoundsValue, freeWhenDone: true)
                self.projection = nil
                free(window)
                window = nil
            } else {
                volume = CPRVolumeData(floatBytesNoCopy: window, pixelsWide: UInt(pixelsWide), pixelsHigh: UInt(pixelsHigh), pixelsDeep: UInt(pixelsDeep),
                                       volumeTransform: volumeTransform, outOfBoundsValue: outOfBoundsValue, freeWhenDone: true)
                window = nil
            }
        }
        lock.unlock()
        completion?(volume)
    }
}
