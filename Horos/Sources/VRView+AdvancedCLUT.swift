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

import AppKit
import IsiXVolumeRendering

// The advanced CLUT of VRView: the colour and opacity curves of the CLUT
// editor (CLUTOpacityView) as VTK's transfer functions. A Swift extension of
// the class, with the same selectors.

/// The curves of an advanced CLUT (NSValue points: x the value, y the height)
/// with the colour of each point; a point without a colour is black.
private func advancedCLUTCurves(_ clut: NSDictionary?) -> [[AdvancedCLUTFunctions.Point]] {
    let colours = clut?.object(forKey: "colors") as? [Any] ?? []
    return (clut?.object(forKey: "curves") as? [Any] ?? []).enumerated().map { index, curve in
        let points = curve as? [NSValue] ?? []
        let pointColours = index < colours.count ? colours[index] as? [NSColor] ?? [] : []
        return points.enumerated().map { pointIndex, value in
            let point = value.pointValue
            let colour = pointIndex < pointColours.count ? pointColours[pointIndex] : nil
            return AdvancedCLUTFunctions.Point(value: Double(point.x), height: Double(point.y),
                                               red: Double(colour?.redComponent ?? 0), green: Double(colour?.greenComponent ?? 0),
                                               blue: Double(colour?.blueComponent ?? 0))
        }
    }
}

extension VRView {

    @objc(setAdvancedCLUT:lowResolution:)
    func setAdvancedCLUT(_ clut: NSMutableDictionary!, lowResolution lowRes: Bool) {
        if horos_controller?.windowWillClose() ?? false { return }

        horos_advancedCLUT = true

        // The curves' values, and the volume's range, as the volume holds them;
        // the opacity divided by the supersampling in volume rendering.
        let functions = AdvancedCLUTFunctions(curves: advancedCLUTCurves(clut),
                                              minimum: Double(horos_controller?.minimumValue() ?? 0),
                                              maximum: Double(horos_controller?.maximumValue() ?? 0),
                                              offset: Double(horos_OFFSET16), valueFactor: Double(horos_valueFactor),
                                              opacityDivisor: renderingMode == 0 ? Double(horos_superSampling) : 1)

        // What was last applied is compared as functions, not as curves: the
        // same curves give other functions after a change of mode (the
        // opacity's divisor) or of a 4D set's value map, and the editor changes
        // its arrays in place.
        guard functions != horos_appliedCLUT || (horos_appliedResolution && !lowRes) else { return }

        let vtk = horos_vtk
        vtk.removeAllColourPoints()
        vtk.removeAllOpacityPoints()
        for node in functions.opacity {
            vtk.addOpacityPoint(at: node.x, value: node.opacity)
        }
        for node in functions.colour {
            vtk.addColourPoint(at: node.x, red: node.red, green: node.green, blue: node.blue)
        }

        horos_appliedCLUT = functions
        horos_appliedResolution = lowRes

        if lowRes {
            vtk.setVolumeMinimumImageSampleDistance(horos_LOD * lowResLODFactor * 2) // was LOD*5
        } else {
            vtk.setVolumeMinimumImageSampleDistance(horos_LOD)
        }

        if lowRes {
            vtk.setBlendingMinimumImageSampleDistance(horos_LOD * lowResLODFactor * 2) // was LOD*5
        } else {
            vtk.setBlendingMinimumImageSampleDistance(horos_LOD)
        }

        needsDisplay = true
    }

    @objc(setAdvancedCLUTWithName:)
    func setAdvancedCLUTWithName(_ name: String!) {
    }

    @objc(advancedCLUT)
    func advancedCLUT() -> Bool {
        return horos_advancedCLUT
    }
}
