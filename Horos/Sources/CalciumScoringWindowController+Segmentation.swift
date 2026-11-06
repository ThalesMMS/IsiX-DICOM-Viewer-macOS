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

// The region growing of the calcium scoring window: a click grows a ROI between
// the lower and upper thresholds from the seed, on the current image, through
// ITKSegmentation3D; an older plain ROI it overlaps is deleted; the vessel's
// ROIs are coloured and summed in the table.
extension CalciumScoringWindowController {

    /// The name of the ROI a preview grows.
    static var previewName: String { NSLocalizedString("Segmentation Preview", comment: "") }

    @IBAction @objc(preview:)
    func preview(_ sender: Any!) {
        computeROIs(withName: Self.previewName, addROIs: false)
    }

    @IBAction @objc(compute:)
    func compute(_ sender: Any!) {
        computeROIs(withName: roiName, addROIs: true)
    }

    /// Grows the ROI `name` from the seed; with `addROIs`, adds the ROIs of
    /// that name to the vessel's, colours them and updates the totals.
    @objc(computeROIsWithName:addROIs:)
    func computeROIs(withName name: String!, addROIs: Bool) {
        guard let viewer else { return }
        viewer.roiDelete(withName: Self.previewName)

        if startingPoint.x == 0 && startingPoint.y == 0 {
            return
        }

        let slice = Int(viewer.imageView()?.curImage ?? 0)

        if let itk = ITKSegmentation3D(viewer.pixList(), viewer.volumePtr(), slice) {
            NSLog("Lower Threshold: %d", lowerThreshold)
            let parametersArray = [NSNumber(value: lowerThreshold), NSNumber(value: upperThreshold)]

            let temporaryName = String(format: "%ld", Int(UInt(Date.timeIntervalSinceReferenceDate)))

            itk.regionGrowing3D(viewer,
                                nil,
                                slice,
                                startingPoint,
                                1, // threshold upper and lower limits type
                                parametersArray, // parameter values
                                false, // next four are used for setting pixels
                                0,
                                false,
                                0,
                                ToolMode(rawValue: 0)!, // Brush ROI
                                1,
                                temporaryName,
                                false)

            // Check that there are no overlaping ROIs
            let newROI = deleteROIsOverlapping(roiNamed: temporaryName, in: viewer)

            newROI?.name = name
        }

        let roiList = viewer.rois(withName: name) as? [ROI] ?? []
        let vesselNames = Self.defaultVesselNames
        for roi in roiList {
            roi.displayCalciumScoring = true
            if addROIs {
                rois.add(roi)
                let colour = CalciumScoringColor.color(roiName: roi.name ?? "", leftCoronary: vesselNames[0],
                                                       leftAnteriorDescending: vesselNames[1], leftCircumflex: vesselNames[2],
                                                       rightCoronary: vesselNames[3])
                roi.rgbcolor = RGBColor(red: colour.red, green: colour.green, blue: colour.blue)
            }
        }

        if addROIs {
            updateTotals()
        }
    }

    /// The ROI the region growing has just made, named `temporaryName` (the
    /// last of that name), after deleting each other plain ROI of the image
    /// that shares a pixel with it.
    private func deleteROIsOverlapping(roiNamed temporaryName: String, in viewer: ViewerController) -> ROI? {
        let roiList = viewer.imageView()?.curRoiList as? [ROI] ?? []
        guard let newROI = roiList.last(where: { ($0.name as NSString?)?.isEqual(to: temporaryName) ?? false }),
              let pix = viewer.imageView()?.curDCM else { return nil }

        let newRoiRect = NSRect(x: CGFloat(newROI.textureUpLeftCornerX), y: CGFloat(newROI.textureUpLeftCornerY),
                                width: CGFloat(newROI.textureWidth), height: CGFloat(newROI.textureHeight))

        var locations: UnsafeMutablePointer<Float>?
        var numberOfValues = 0
        let newRoiValues = pix.getROIValue(&numberOfValues, newROI, &locations)
        defer {
            free(locations)
            free(newRoiValues)
        }

        var roisToDelete: [ROI] = []

        for r in roiList where r.type == .tPlain && r !== newROI {
            let roiRect = NSRect(x: CGFloat(r.textureUpLeftCornerX), y: CGFloat(r.textureUpLeftCornerY),
                                 width: CGFloat(r.textureWidth), height: CGFloat(r.textureHeight))

            guard NSIntersectsRect(roiRect, newRoiRect) else { continue }

            var l: UnsafeMutablePointer<Float>?
            var n = 0
            let nRV = pix.getROIValue(&n, r, &l)

            let intersect = CalciumScoringOverlap.intersects(
                values: UnsafeBufferPointer(start: nRV, count: nRV == nil ? 0 : n),
                locations: UnsafeBufferPointer(start: l, count: l == nil ? 0 : n * 2),
                newValues: UnsafeBufferPointer(start: newRoiValues, count: newRoiValues == nil ? 0 : numberOfValues),
                newLocations: UnsafeBufferPointer(start: locations, count: locations == nil ? 0 : numberOfValues * 2))

            free(l)
            free(nRV)

            if intersect {
                // Delete this ROI
                roisToDelete.append(r)
            }
        }

        for r in roisToDelete {
            viewer.delete(r)
        }

        return newROI
    }

    /// Sums the score, mass and volume of each vessel's ROIs, at the lower
    /// threshold, into the table and the totals.
    @objc(updateTotals)
    func updateTotals() {
        let rows = (vessels as? [NSMutableDictionary]) ?? []
        let rowNames = rows.map { $0.object(forKey: "vesselName") as? String ?? "" }
        let allROIs = rois.allObjects as NSArray
        let threshold = lowerThreshold

        let result = CalciumScoreTotals.compute(rowNames: rowNames, totalName: NSLocalizedString("Total", comment: "")) { vesselName in
            let filteredROIs = allROIs.filtered(using: NSPredicate(format: "name like %@", vesselName))
            return filteredROIs.compactMap { $0 as? ROI }.map { roi in
                roi.calciumThreshold = threshold
                return CalciumScoreSums(score: roi.calciumScore(), mass: roi.calciumMass(), volume: roi.calciumVolume())
            }
        }

        for (row, sums) in zip(rows, result.rows) {
            guard let sums else { continue }
            row.setValue(NSNumber(value: sums.score), forKey: "score")
            row.setValue(NSNumber(value: sums.mass), forKey: "mass")
            row.setValue(NSNumber(value: sums.volume), forKey: "volume")
        }
        if let total = result.total {
            totalCalciumScore = total.score
            totalCalciumMass = total.mass
            totalCalciumVolume = total.volume
        }
    }
}
