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

// The colours and the stroke of a volume ROI: those of the 2D ROIs it stands
// for. A brush ROI (tPlain) gives the fill, every other ROI the stroke.
extension OSIROI {

    /// The fill colour, with the opacity of the brush ROIs behind it; nil
    /// when there are none, or when their colours or opacities differ.
    @objc(fillColor)
    public func fillColor() -> NSColor! {
        return OSIROI.commonColor(of: osiriXROIs(), brushes: true)
    }

    /// Sets the colour of the brush ROIs behind the receiver, and its alpha
    /// as their opacity; nil if the ROI should not be drawn.
    @objc(setFillColor:)
    public func setFillColor(_ color: NSColor!) {
        OSIROI.setColor(color, of: osiriXROIs(), brushes: true)
    }

    /// The stroke colour, with the opacity of the outlined ROIs behind it;
    /// nil when there are none, or when their colours or opacities differ.
    @objc(strokeColor)
    public func strokeColor() -> NSColor! {
        return OSIROI.commonColor(of: osiriXROIs(), brushes: false)
    }

    /// Sets the colour of the outlined ROIs behind the receiver, and its
    /// alpha as their opacity; nil if its outline should not be drawn.
    @objc(setStrokeColor:)
    public func setStrokeColor(_ color: NSColor!) {
        OSIROI.setColor(color, of: osiriXROIs(), brushes: false)
    }

    /// The stroke thickness of the 2D ROIs behind the receiver, 0 when they differ.
    @objc(strokeThickness)
    public func strokeThickness() -> CGFloat {
        let thicknesses = (osiriXROIs() ?? NSSet()).compactMap { ($0 as? ROI).map { Double($0.thickness) } }
        return CGFloat(VolumeROIMetrics.commonThickness(thicknesses))
    }

    @objc(setStrokeThickness:)
    public func setStrokeThickness(_ strokeThickness: CGFloat) {
        for case let roi as ROI in osiriXROIs() ?? NSSet() {
            roi.thickness = Float(strokeThickness)
        }
    }

    /// The first ROI's colour with its opacity, nil when another ROI's colour
    /// differs. Both getters skip the ROIs their setter leaves alone, so that
    /// the order of the set does not matter.
    private static func commonColor(of rois: NSSet?, brushes: Bool) -> NSColor? {
        var color: NSColor?
        for case let roi as ROI in rois ?? NSSet() {
            if (roi.type == .tPlain) != brushes {
                continue
            }
            if let common = color {
                if !common.isEqual(roi.nsColor) {
                    return nil
                }
            } else {
                color = roi.nsColor?.withAlphaComponent(CGFloat(roi.opacity))
            }
        }
        return color
    }

    private static func setColor(_ color: NSColor?, of rois: NSSet?, brushes: Bool) {
        for case let roi as ROI in rois ?? NSSet() where (roi.type == .tPlain) == brushes {
            roi.nsColor = color?.withAlphaComponent(1)
            roi.opacity = Float(color?.alphaComponent ?? 0)
        }
    }
}
