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
import IsiXROI

/// The first volume ROI of an outlined 2D ROI: a measure, an open or a
/// closed polygon, as a path in patient space whose ends point out.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIPathROI.h> are those of the former class.
@objc(OSIPathROI)
public final class OSIPathROI: OSIROI {
    private let _osiriXROI: ROI?
    private var _bezierPath: N3MutableBezierPath?

    // for now implement closed poly first
    /// The ROI of `roi` (a measure, an open or a closed polygon) drawn on the
    /// slice whose pix space `pixToDICOMTransfrom` carries to patient space;
    /// nil for another tool.
    @objc(initWithOsiriXROI:pixToDICOMTransfrom:)
    public init?(osiriXROI roi: ROI!, pixToDICOMTransfrom: N3AffineTransform) {
        _osiriXROI = roi
        super.init()

        let points: [NSPoint]
        let kind: VolumeROIOutline.Kind
        switch roi?.type {
        case .tMesure?:
            // The measure's two ends, read as -pointAtIndex: reads them.
            kind = .measure
            points = [roi.point(at: 0), roi.point(at: 1)]
        case .tOPolygon?:
            kind = .openPolygon
            points = (roi.points as? [MyPoint] ?? []).map { $0.point }
        case .tCPolygon?:
            kind = .closedPolygon
            points = (roi.points as? [MyPoint] ?? []).map { $0.point }
        default:
            return nil
        }
        _bezierPath = OSIROIVolumeGeometry.pathOutline(kind: kind, points: points, pixToDICOM: pixToDICOMTransfrom)
    }

    @objc(name)
    public override func name() -> String! {
        return _osiriXROI?.name
    }

    @objc(convexHull)
    public override func convexHull() -> [Any]! {
        return OSIROIVolumeGeometry.hull(of: _bezierPath).map { NSValue(n3Vector: $0) as Any }
    }
}
