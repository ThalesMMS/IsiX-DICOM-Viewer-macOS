/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Accelerate
import Foundation

/// A float image converted to unsigned 16-bit integers ("FTo16U") or back
/// ("16UToF") with vImage, in horizontal bands, one per processor, all at
/// once; the call returns when every band is done. One conversion runs at a
/// time, as the former threads, which shared one lock, did.
public enum ParallelImageConversion {
    public enum Kind: Sendable {
        case floatToUInt16
        case uint16ToFloat

        /// The kind a caller names, nil for another name.
        public init?(name: String?) {
            switch name {
            case "FTo16U": self = .floatToUInt16
            case "16UToF": self = .uint16ToFloat
            default: return nil
            }
        }
    }

    private static let oneAtATime = NSLock()

    /// The bands of `height` rows for `parts` processors: from (i * height) / parts to ((i+1) * height) / parts.
    public static func bands(height: Int, parts: Int) -> [(from: Int, to: Int)] {
        return (0..<parts).map { ((Int($0) * height) / parts, ((Int($0) + 1) * height) / parts) }
    }

    /// Converts `src` into `dst` with the offset and the scale vImage takes,
    /// with as many bands as there are processors. A kind nil (an unknown name)
    /// converts nothing; `unknown` is called once per band, as the former
    /// threads logged it.
    public static func convert(_ kind: Kind?, src: UnsafePointer<vImage_Buffer>, dst: UnsafePointer<vImage_Buffer>,
                               offset: Float, scale: Float, unknown: @Sendable (Int) -> Void = { _ in }) {
        let processors = ProcessInfo.processInfo.processorCount
        oneAtATime.lock()
        defer { oneAtATime.unlock() }
        let source = src.pointee, destination = dst.pointee
        let parts = bands(height: Int(Int32(truncatingIfNeeded: Int(source.height))), parts: processors)
        // The bands are disjoint rows of the two buffers.
        nonisolated(unsafe) let base = (source, destination)
        DispatchQueue.concurrentPerform(iterations: parts.count) { index in
            let band = parts[index]
            var s = base.0, d = base.1
            let rows = band.to - band.from
            s.height = vImagePixelCount(rows)
            d.height = vImagePixelCount(rows)
            s.data = s.data.map { $0 + band.from * s.rowBytes }
            d.data = d.data.map { $0 + band.from * d.rowBytes }
            switch kind {
            case .floatToUInt16?:
                _ = vImageConvert_FTo16U(&s, &d, offset, scale, vImage_Flags(kvImageDoNotTile))
            case .uint16ToFloat?:
                _ = vImageConvert_16UToF(&s, &d, offset, scale, vImage_Flags(kvImageDoNotTile))
            case nil:
                unknown(index)
            }
        }
    }
}
