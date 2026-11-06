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

// The volume ROIs draw on the view's canvas through ROIGL, the OpenGL-shaped
// calls of the 2D ROIs (ROI+Drawing.swift), as they drew through those of
// ROICanvasGL.h. The canvas keeps one matrix: the model-view mode they set
// changed nothing, and is left out.
extension ROIGL {
    static let triangleStrip: UInt32 = 0x0005, quads: UInt32 = 0x0007

    static func vertex3d(_ x: Double, _ y: Double, _ z: Double) { ROICanvas.current?.vertex(x: x, y: y, z: z) }
    static func multMatrixd(_ m: UnsafePointer<Double>) { ROICanvas.current?.mult(m) }
}

// What the volume ROIs draw alike on the view's canvas, in patient space.
extension OSIROI {

    /// The column-major OpenGL matrix of `transform`, for ROIGL.multMatrixd.
    static func openGLMatrix(_ transform: N3AffineTransform) -> [Double] {
        var matrix = [Double](repeating: 0, count: 16)
        N3AffineTransformGetOpenGLMatrixd(transform, &matrix)
        return matrix
    }

    /// `path`, flattened finer than its mask is, as one line strip.
    static func drawLineStrip(_ path: N3BezierPath?) {
        let flattenedPath = path?.flattening(N3BezierDefaultFlatness / 5.0)
        ROIGL.begin(ROIGL.lineStrip)
        for i in 0..<(flattenedPath?.elementCount() ?? 0) {
            var endpoint = N3VectorZero
            flattenedPath?.element(at: i, control1: nil, control2: nil, endpoint: &endpoint)
            ROIGL.vertex3d(Double(endpoint.x), Double(endpoint.y), Double(endpoint.z))
        }
        ROIGL.end()
    }

    /// Each run of `maskRuns` as a line through the middle of its row, from
    /// the volume's indexes to patient space by `inverseVolumeTransform`.
    static func drawMaskRunLines(_ maskRuns: NSArray?, inverseVolumeTransform: N3AffineTransform) {
        ROIGL.begin(ROIGL.lines)
        for case let maskRunValue as NSValue in maskRuns ?? NSArray() {
            let maskRun = maskRunValue.osiroiMaskRun()

            var lineStart = N3VectorMake(CGFloat(maskRun.widthRange.location), CGFloat(maskRun.heightIndex) + 0.5, CGFloat(maskRun.depthIndex))
            var lineEnd = N3VectorMake(CGFloat(NSMaxRange(maskRun.widthRange)), CGFloat(maskRun.heightIndex) + 0.5, CGFloat(maskRun.depthIndex))

            lineStart = N3VectorApplyTransform(lineStart, inverseVolumeTransform)
            lineEnd = N3VectorApplyTransform(lineEnd, inverseVolumeTransform)

            ROIGL.vertex3d(Double(lineStart.x), Double(lineStart.y), Double(lineStart.z))
            ROIGL.vertex3d(Double(lineEnd.x), Double(lineEnd.y), Double(lineEnd.z))
        }
        ROIGL.end()
    }

    /// The transform from the home volume's indexes back to patient space.
    func inverseHomeVolumeTransform() -> N3AffineTransform {
        return N3AffineTransformInvert(homeFloatVolumeData()?.volumeTransform ?? N3AffineTransform())
    }

    /// +[OSIROIMask ROIMaskFromVolumeData:] for a volume the CPR generator
    /// made, sent as the Objective-C sent it: the generator answers a
    /// CPRVolumeData, which the method reads as the float volume it is not.
    static func roiMask(fromResampled volume: CPRVolumeData?) -> OSIROIMask! {
        typealias Send = @convention(c) (AnyObject, Selector, CPRVolumeData?) -> Unmanaged<OSIROIMask>?
        let selector = NSSelectorFromString("ROIMaskFromVolumeData:")
        let send = unsafeBitCast(method_getImplementation(class_getClassMethod(OSIROIMask.self, selector)!), to: Send.self)
        return send(OSIROIMask.self, selector, volume)?.takeUnretainedValue()
    }
}
