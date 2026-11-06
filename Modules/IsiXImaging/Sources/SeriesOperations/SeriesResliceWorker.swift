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

import Dispatch
import Foundation

// The pixel work of a 2D viewer's reslice: gathering every new slice from the
// stack, along its rows or its columns, and scaling it to square pixels. The
// viewer allocates the new volume and makes the new slices; the gathering
// runs on the process's SeriesResliceWorker, one reslice at a time, each on
// every processor.

/// The new slices of a reslice of one time point, and where their pixels
/// come from. It holds the addresses of the stack's slices and of the new
/// volume, which the viewer keeps alive and leaves alone until the worker is
/// done with them: that is what makes it safe to send.
public struct SeriesResliceJob: @unchecked Sendable {

    enum Source {
        /// X reslice: the rows of these slices (an even number of them), of
        /// `width` floats each.
        case rows([UnsafePointer<Float>], width: Int)
        /// Y reslice: the columns of `count` slices (an even number of them)
        /// stored one after the other from `base` (the last one for a
        /// positive sign, read backwards), `sliceFloatCount` floats each, in
        /// rows of `rowFloats`.
        case columns(base: UnsafePointer<Float>, count: Int, sliceFloatCount: Int, rowFloats: Int)
    }

    let source: Source
    let plan: SeriesReslicePlan
    let sign: Double
    /// The pixels of each new slice, `plan.width`×`plan.height` floats.
    let destinations: [UnsafeMutablePointer<Float>]

    /// An X reslice: new slice i is row i of each of `slices`.
    public static func rows(of slices: [UnsafePointer<Float>], sourceWidth: Int, plan: SeriesReslicePlan, sign: Double,
                            into destinations: [UnsafeMutablePointer<Float>]) -> SeriesResliceJob {
        SeriesResliceJob(source: .rows(slices, width: sourceWidth), plan: plan, sign: sign, destinations: destinations)
    }

    /// A Y reslice: new slice i is column i of each of the `count` slices
    /// from `base`.
    public static func columns(from base: UnsafePointer<Float>, count: Int, sliceFloatCount: Int, rowFloats: Int,
                               plan: SeriesReslicePlan, sign: Double, into destinations: [UnsafeMutablePointer<Float>]) -> SeriesResliceJob {
        SeriesResliceJob(source: .columns(base: base, count: count, sliceFloatCount: sliceFloatCount, rowFloats: rowFloats),
                         plan: plan, sign: sign, destinations: destinations)
    }

    /// Gathers new slice `index`, and scales it to square pixels when the
    /// plan says so. Only the rows gathered are scaled, one per slice taken
    /// from the stack: the last slice of an odd stack is left out, so its row
    /// is never written, and scaling it would spread whatever the new volume
    /// held there (a NaN reaches the whole slice).
    func gather(_ index: Int) {
        let destination = destinations[index]
        switch source {
        case let .rows(slices, width):
            SeriesReslice.gatherRows(slices, row: index, sourceWidth: width, width: plan.width, into: destination, sign: sign)
            if plan.square {
                SeriesReslice.scaleRows(destination, rows: slices.count, newRows: plan.height, width: plan.width)
            }
        case let .columns(base, count, sliceFloatCount, rowFloats):
            SeriesReslice.gatherColumns(base, column: index, count: count, sliceFloatCount: sliceFloatCount,
                                        rowFloats: rowFloats, width: plan.width, into: destination, sign: sign)
            if plan.square {
                SeriesReslice.scaleRows(destination, rows: count, newRows: plan.height, width: plan.width)
            }
        }
    }
}

/// The reslices of 2D viewers: one at a time, each gathering its new slices
/// on every processor. The process has one, which all its viewers share. It
/// runs on a serial queue of its own, so a viewer that has to wait for its new
/// slices inside a synchronous action waits for the queue alone, never for the
/// threads of Swift concurrency.
public actor SeriesResliceWorker {

    private let queue = DispatchSerialQueue(label: "IsiX series reslice")

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init() {}

    /// Gathers every new slice of `job`.
    public func gather(_ job: SeriesResliceJob) {
        DispatchQueue.concurrentPerform(iterations: job.destinations.count) { job.gather($0) }
    }

    /// Gathers every new slice of `job` and returns when they are all done,
    /// for a caller that cannot await. Never call it from the worker itself.
    public nonisolated func gatherAndWait(_ job: SeriesResliceJob) {
        queue.sync {
            self.assumeIsolated { $0.gather(job) }
        }
    }
}
