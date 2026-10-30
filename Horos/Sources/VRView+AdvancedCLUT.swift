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

// The advanced CLUT of VRView: the colour and opacity curves of the CLUT
// editor (CLUTOpacityView) as VTK's transfer functions. A Swift extension of
// the class, with the same selectors.

/// The curves and colours of an advanced CLUT as they are now: the CLUT editor
/// changes its arrays in place, so the CLUT last applied is kept as a copy and
/// compared with the next one value by value (NSValue points, NSColors).
private func advancedCLUTSnapshot(_ clut: NSDictionary?) -> NSDictionary {
    let curves = NSMutableArray()
    for curve in (clut?.object(forKey: "curves") as? NSArray) ?? [] {
        curves.add(NSArray(array: curve as? [Any] ?? []))
    }
    let colors = NSMutableArray()
    for pointColors in (clut?.object(forKey: "colors") as? NSArray) ?? [] {
        colors.add(NSArray(array: pointColors as? [Any] ?? []))
    }
    return NSDictionary(objects: [curves, colors], forKeys: ["curves" as NSString, "colors" as NSString])
}

extension VRView {

    @objc(setAdvancedCLUT:lowResolution:)
    func setAdvancedCLUT(_ clut: NSMutableDictionary!, lowResolution lowRes: Bool) {
        if horos_controller?.windowWillClose() ?? false { return }

        horos_advancedCLUT = true

        let curves = clut?.object(forKey: "curves") as? NSArray ?? NSArray()
        let pointColors = clut?.object(forKey: "colors") as? NSArray ?? NSArray()

        let clutSnapshot = advancedCLUTSnapshot(clut)

        // -isEqual: of a dictionary is -isEqualToDictionary:, NO for nil.
        guard !clutSnapshot.isEqual(horos_appliedCurves) || (horos_appliedResolution && !lowRes) else { return }

        let vtk = horos_vtk
        vtk.removeAllColourPoints()
        vtk.removeAllOpacityPoints()

        vtk.addOpacitySegment(from: Double(horos_controller?.minimumValue() ?? 0), value: 0.0,
                                  to: Double(horos_controller?.maximumValue() ?? 0), value: 0.0)

        let offset = Double(horos_OFFSET16), valueFactor = Double(horos_valueFactor)
        for i in 0..<curves.count {
            let aCurve = NSMutableArray(array: curves.object(at: i) as? [Any] ?? [])
            let someColors = NSMutableArray(array: pointColors.object(at: i) as? [Any] ?? [])
            for j in 0..<aCurve.count {
                let point = (aCurve.object(at: j) as? NSValue)?.pointValue ?? .zero
                let color = someColors.object(at: j) as? NSColor
                vtk.addColourPoint(at: (offset + Double(point.x)) * valueFactor,
                                     red: Double(color?.redComponent ?? 0), green: Double(color?.greenComponent ?? 0),
                                     blue: Double(color?.blueComponent ?? 0))

                var opacityAdapter: Float = 1
                if renderingMode == 0 { // VR
                    opacityAdapter = horos_superSampling
                }

                let o = Float(Double(point.y) * Double(point.y) / Double(opacityAdapter))

                vtk.addOpacityPoint(at: (offset + Double(point.x)) * valueFactor, value: Double(o))
            }
        }

        horos_appliedCurves = clutSnapshot as? [AnyHashable: Any]
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
