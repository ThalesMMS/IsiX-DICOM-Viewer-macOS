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

// The brush ROIs of the 2D viewer, with the selectors of the former
// Objective-C methods (the morphology filters, -applyMorphology:action:radius:
// sendNotification:, the conversions between brush and polygon ROIs, the
// merge of brushes, -imageIndexOfROI:). The work is ViewerBrushROIs', over
// IsiXROI's BrushROIOperations.

/// The work of one ROI of the 2D viewer, run on an operation queue: a fill
/// of pixels ({action: setPixel or setPixelRoi, curPix, roi, newValue,
/// minValue, maxValue, outside, stackNo, revert, addition}) or a morphology
/// filter of a brush ({action: close, open, dilate or erode, filter, roi,
/// radius}).
@objc(ViewerControllerOperation)
final class ViewerControllerOperation: Operation, @unchecked Sendable {
    private let ctrl: ViewerController?
    private let dict: NSDictionary?

    @objc(initWithController:dict:)
    init(controller c: ViewerController?, dict d: NSDictionary?) {
        ctrl = c
        dict = d
        super.init()
    }

    override func main() {
        autoreleasepool {
            guard let dict else { return }
            let action = dict.object(forKey: "action") as? String
            func float(_ key: String) -> Float { (dict.object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
            func bool(_ key: String) -> Bool { (dict.object(forKey: key) as? NSNumber)?.boolValue ?? false }
            func int(_ key: String) -> Int32 { (dict.object(forKey: key) as? NSNumber)?.int32Value ?? 0 }

            // ** Set Pixels
            if action == "setPixel" || action == "setPixelRoi" {
                (dict.object(forKey: "curPix") as? DCMPix)?.fillROI(action == "setPixelRoi" ? dict.object(forKey: "roi") as? ROI : nil,
                                                                     newVal: float("newValue"), minValue: float("minValue"), maxValue: float("maxValue"),
                                                                     outside: bool("outside"), orientationStack: 2, stackNo: Int(int("stackNo")),
                                                                     restore: bool("revert"), addition: bool("addition"))
            }

            // ** Math Morphology
            let filter = dict.object(forKey: "filter") as? ITKBrushROIFilter
            let roi = dict.object(forKey: "roi") as? ROI
            switch action {
            case "close": filter?.close(roi, withStructuringElementRadius: int("radius"))
            case "open": filter?.open(roi, withStructuringElementRadius: int("radius"))
            case "dilate": filter?.dilate(roi, withStructuringElementRadius: int("radius"))
            case "erode": filter?.erode(roi, withStructuringElementRadius: int("radius"))
            default: break
            }
        }
    }
}

public extension ViewerController {

    /// Runs the morphology filter `action` (open, close, erode, dilate) of
    /// radius `radius` on the brush ROIs `rois`, in parallel, under the ROI
    /// lock; posts OsirixROIChangeNotification for each when
    /// `sendNotification`.
    @objc(applyMorphology:action:radius:sendNotification:)
    func applyMorphology(_ rois: [Any]!, action: String!, radius: Int, sendNotification: Bool) {
        ViewerBrushROIs.applyMorphology(rois ?? [], action: action, radius: radius, sendNotification: sendNotification, in: self)
    }

    /// Shows the radius of the structuring element the slider is at.
    @objc(setStructuringElementRadius:)
    @IBAction func setStructuringElementRadius(_ sender: Any!) {
        horos_structuringElementRadiusTextField?.stringValue = String(format: "%d", horos_structuringElementRadiusSlider?.intValue ?? 0)
    }

    /// Ends the brush filter sheet; its OK button (tag 1) runs the filter on
    /// the selected brush ROI, or on every ROI of its name.
    @objc(morphoSelectedBrushROIWithRadius:)
    @IBAction func morphoSelectedBrushROIWithRadius(_ sender: Any!) {
        ViewerBrushROIs.endFilterSheet(sender, in: self)
    }

    /// Chooses the filter of the menu item (tag 0 erode, 1 dilate, 2 close,
    /// 3 open) and asks for its radius, for a selected brush ROI.
    @objc(morphoSelectedBrushROI:)
    @IBAction func morphoSelectedBrushROI(_ sender: Any!) {
        ViewerBrushROIs.beginFilterSheet(sender, in: self)
    }

    /// A brush ROI of the area of a closed or open polygon, a pencil or an
    /// oval ROI (which becomes a closed polygon), nil when it is empty.
    @objc(convertPolygonROItoBrush:)
    func convertPolygonROItoBrush(_ selectedROI: ROI!) -> ROI! {
        selectedROI.flatMap { ViewerBrushROIs.brush(from: $0, in: self) }
    }

    /// A closed polygon of `numPoints` points along the contour of a brush ROI.
    @objc(convertBrushROItoPolygon:numPoints:)
    func convertBrushROItoPolygon(_ selectedROI: ROI!, numPoints: Int32) -> ROI! {
        selectedROI.flatMap { ViewerBrushROIs.polygon(from: $0, numPoints: numPoints, in: self) }
    }

    /// The index of the image of the current time point whose list holds
    /// `c`, -1 when none does.
    @objc(imageIndexOfROI:)
    func imageIndexOfROI(_ c: ROI!) -> Int32 {
        ViewerBrushROIs.imageIndex(of: c, in: self)
    }

    /// Merges the brush ROIs of `s` into the last of them, removing the
    /// others from `roiListContained`.
    @objc(mergeBrushROI:ROIs:ROIList:)
    func mergeBrushROI(_ sender: Any!, rois s: [Any]!, roiList roiListContained: NSMutableArray!) {
        ViewerBrushROIs.merge(s ?? []) { roiListContained?.remove($0) }
    }

    /// Merges the selected brush ROIs of the current image.
    @objc(mergeBrushROI:)
    @IBAction func mergeBrushROI(_ sender: Any!) {
        let slices = ViewerROISlices(self, movie: Int(horos_curMovieIndex))
        mergeBrushROI(sender, rois: selectedROIs() as? [Any], roiList: slices?.list(at: Int(horos_imageView?.curImage ?? 0)))
    }

    /// Turns the ROIs the "apply to" window chooses into brushes, or the
    /// brushes into polygons of 100 points.
    @objc(convertBrushPolygon:)
    @IBAction func convertBrushPolygon(_ sender: Any!) {
        ViewerBrushROIs.convertBrushPolygon(in: self)
    }
}
