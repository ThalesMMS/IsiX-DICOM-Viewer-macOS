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

import AppKit
import Synchronization

/// The part of each series' frames that holds an image, for the fit to the
/// window that opening a viewer asks for: the union of the content rectangles
/// of a series' loaded frames, when they all share the first one's geometry.
///
/// Measured on the load thread of the viewer, after the frames are loaded and
/// before they are shown. The frames of a series are measured by a few
/// workers at once, at most four and one fewer than the processors, and the
/// load thread waits for them before it measures the next series.
enum OpeningContentBounds {
    /// The frames of one series, handed to the workers that measure them.
    ///
    /// `@unchecked Sendable`: DCMPix is not Sendable. Each worker reads only
    /// the loaded frames it takes, which nothing writes while the series is
    /// measured, and the load thread waits for the workers before the frames
    /// go anywhere else, so the volume storage outlives every read, even when
    /// the viewer closes or replaces its series meanwhile.
    private struct Frames: @unchecked Sendable {
        let frames: [DCMPix]
    }

    /// What the workers of one series find, merged as they find it.
    private final class Envelope: Sendable {
        let state = Mutex((envelope: NSRect.zero, compatible: true))
        let next = Atomic<Int>(0)
    }

    /// The envelope of each series in `series` whose frames are loaded and
    /// share one geometry, by its index there; nil once `loadThread` is
    /// cancelled.
    static func measure(series: [[DCMPix]], loadThread: ObservedThread?) -> [Int: NSRect]? {
        let workers = max(1, min(4, ProcessInfo.processInfo.processorCount - 1))
        var results: [Int: NSRect] = [:]
        for (index, pixels) in series.enumerated() {
            if loadThread?.isCancelled ?? false { return nil }
            guard let first = pixels.first, first.isLoaded() else { continue }
            let width = first.pwidth, height = first.pheight
            let ratio = first.pixelRatio
            let found = Envelope()
            let frames = Frames(frames: pixels)
            DispatchQueue.concurrentPerform(iterations: min(workers, pixels.count)) { _ in
                while true {
                    let taken = found.next.wrappingAdd(1, ordering: .relaxed).oldValue
                    guard taken < frames.frames.count, !(loadThread?.isCancelled ?? false) else { return }
                    autoreleasepool {
                        let pix = frames.frames[taken]
                        if !pix.isLoaded() || pix.pwidth != width || pix.pheight != height ||
                            !pix.pixelRatio.isFinite || abs(pix.pixelRatio - ratio) > 1e-6 {
                            found.state.withLock { $0.compatible = false }
                            return
                        }
                        let hu = pix.modalityString == "CT" && pix.rescaleType == "HU"
                        var bounds = HorosContentRect()
                        // Unknown/empty content contributes the full frame; it
                        // must not let a small positive slice over-zoom the stack.
                        var rect = NSMakeRect(0, 0, CGFloat(width), CGFloat(height))
                        if HorosFindContentBounds(pix.fImage, pix.isRGB, hu, width, height, &bounds) {
                            rect = NSMakeRect(bounds.x, bounds.y, bounds.width, bounds.height)
                        }
                        found.state.withLock { $0.envelope = NSUnionRect($0.envelope, rect) }
                    }
                }
            }
            if loadThread?.isCancelled ?? false { return nil }
            let (envelope, compatible) = found.state.withLock { ($0.envelope, $0.compatible) }
            if compatible { results[index] = envelope }
        }
        return results
    }
}
