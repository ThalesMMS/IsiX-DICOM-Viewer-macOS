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
import IsiXROI

/// One brush filtered on another thread while the main thread waits;
/// each ROI is only touched by its own filter.
private struct ViewerBrushFiltering: @unchecked Sendable {
    let roi: ROI
    let filter: ITKBrushROIFilter
    let morphology: BrushROIOperations.Morphology?
    let radius: Int32

    func run() {
        switch morphology {
        case .close: filter.close(roi, withStructuringElementRadius: radius)
        case .open: filter.open(roi, withStructuringElementRadius: radius)
        case .dilate: filter.dilate(roi, withStructuringElementRadius: radius)
        case .erode: filter.erode(roi, withStructuringElementRadius: radius)
        case nil: break
        }
    }
}

/// The brush ROIs of a 2D viewer: the morphology filters (erode, dilate,
/// open, close) and their sheet, the conversions between brush and polygon
/// ROIs, and the merge of brushes. The filter a menu item asks for, the
/// brushes a merge takes and the polygon a brush becomes are IsiXROI's
/// BrushROIOperations; the masks are filtered by ITKBrushROIFilter. The
/// viewer passes itself to each call: nothing here keeps it.
@MainActor enum ViewerBrushROIs {

    /// Runs the morphology filter `action` (open, close, erode, dilate) of
    /// radius `radius` on the brush ROIs `rois`, side by side, under the ROI
    /// lock; announces a change of each when `sendNotification`.
    static func applyMorphology(_ rois: [Any], action: String?, radius: Int, sendNotification: Bool, in viewer: ViewerController) {
        NSLog("****** applyMorphology - START")

        viewer.horos_roiLock?.lock()

        if let exception = HorosObjCException.caught({
            let filter = ITKBrushROIFilter()
            let morphology = action.flatMap(BrushROIOperations.Morphology.init(rawValue:))
            let work = rois.compactMap { $0 as? ROI }.map {
                ViewerBrushFiltering(roi: $0, filter: filter, morphology: morphology, radius: Int32(truncatingIfNeeded: radius))
            }
            DispatchQueue.concurrentPerform(iterations: work.count) { work[$0].run() }
        }) {
            _N2LogExceptionImpl(exception, true, "-[ViewerController applyMorphology:action:radius:sendNotification:]")
        }

        viewer.horos_roiLock?.unlock()

        if sendNotification {
            for roi in rois {
                ViewerROIEdits.post(.OsirixROIChange, roi)
            }
        }

        NSLog("****** applyMorphology - END")
    }

    /// Ends the brush filter sheet; its OK button (tag 1) runs the filter on
    /// the selected brush ROI, or on every ROI of its name.
    static func endFilterSheet(_ sender: Any?, in viewer: ViewerController) {
        viewer.horos_brushROIFilterOptionsWindow?.orderOutAndEndSheet()

        guard ViewerSender.tag(sender) != 0 else { return }
        let selectedROI = viewer.selectedROI()

        let wait = WaitRendering(NSLocalizedString("Processing...", comment: ""))
        wait?.showWindow(viewer)
        let radius = Int(viewer.horos_structuringElementRadiusSlider?.intValue ?? 0)
        if (viewer.horos_brushROIFilterOptionsAllWithSameName?.state ?? .off) == .off {
            guard let selectedROI else {
                // [NSArray arrayWithObject: nil], as the Objective-C sent it.
                NSException(name: .invalidArgumentException,
                            reason: "*** -[NSArray initWithObjects:count:]: attempt to insert nil object from objects[0]", userInfo: nil).raise()
                return
            }
            viewer.applyMorphology([selectedROI], action: viewer.horos_morphoFunction, radius: radius, sendNotification: true)
        } else {
            viewer.applyMorphology(viewer.rois(withName: selectedROI?.name, in4D: true) as? [Any], action: viewer.horos_morphoFunction,
                                   radius: radius, sendNotification: true)
        }
        wait?.close()
    }

    /// Chooses the filter of the menu item (tag 0 erode, 1 dilate, 2 close,
    /// 3 open) and asks for its radius, for a selected brush ROI.
    static func beginFilterSheet(_ sender: Any?, in viewer: ViewerController) {
        viewer.horosLoadViewerPanels()

        let selectedROI = viewer.selectedROI()

        viewer.horos_morphoFunction = BrushROIOperations.Morphology(tag: ViewerSender.tag(sender))?.rawValue

        if let selectedROI, selectedROI.type == .tPlain {
            viewer.add(toUndoQueue: "roi")

            if let options = viewer.horos_brushROIFilterOptionsWindow {
                viewer.window?.beginSheet(options, completionHandler: nil)
            }
        } else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Brush ROI Error", comment: ""),
                                            message: NSLocalizedString("Select a Brush ROI before to run the filter.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    /// A brush ROI of the area of a closed or open polygon, a pencil or an
    /// oval ROI (which becomes a closed polygon), nil when it is empty.
    static func brush(from selectedROI: ROI, in viewer: ViewerController) -> ROI? {
        if selectedROI.type == .tOval {
            let points = selectedROI.points
            selectedROI.type = .tCPolygon
            selectedROI.points = points
        }

        guard selectedROI.type == .tCPolygon || selectedROI.type == .tOPolygon || selectedROI.type == .tPencil else { return nil }
        var s = NSSize.zero
        var o = NSPoint.zero
        guard let texture = DCMPix.mapFromPolygonROI(selectedROI, size: &s, origin: &o) else { return nil }
        defer { free(texture) }
        let pix = viewer.horos_imageView?.curDCM
        let brush = ROI(texture: texture, textWidth: Int32(s.width), textHeight: Int32(s.height), textName: "",
                        positionX: Int32(o.x), positionY: Int32(o.y),
                        spacingX: Float(pix?.pixelSpacingX ?? 0), spacingY: Float(pix?.pixelSpacingY ?? 0),
                        imageOrigin: NSPoint(x: pix?.originX ?? 0, y: pix?.originY ?? 0))
        // NO means that the ROI is NOT empty.
        return brush?.reduceTextureIfPossible() == false ? brush : nil
    }

    /// A closed polygon of `numPoints` points along the contour of a brush ROI.
    static func polygon(from selectedROI: ROI, numPoints: Int32, in viewer: ViewerController) -> ROI? {
        guard selectedROI.type == .tPlain else { return nil }
        let polygon = viewer.horosMakeROI(.tCPolygon)

        let contour = ITKSegmentation3D.extractContour(selectedROI.textureBuffer, width: Int(selectedROI.textureWidth),
                                                       height: Int(selectedROI.textureHeight), numPoints: Int(numPoints)) as? [Any] ?? []
        let points = BrushROIOperations.polygonPoints(contour: contour.compactMap { ($0 as? MyPoint)?.point },
                                                      maskCorner: (selectedROI.textureUpLeftCornerX, selectedROI.textureUpLeftCornerY),
                                                      numPoints: Int(numPoints)) { ROI.pointBetweenPoint($0, and: $1, ratio: $2) }
        polygon?.points = ViewerROIInterchange.myPoints(points)
        return polygon
    }

    /// The index of the image of the current time point whose list holds
    /// `roi`, -1 when none does.
    static func imageIndex(of roi: ROI?, in viewer: ViewerController) -> Int32 {
        let movie = Int(viewer.horos_curMovieIndex)
        guard let slices = ViewerROISlices(viewer, movie: movie) else { return -1 }
        let imageCount = viewer.horos_pixList(at: movie)?.count ?? 0
        for x in 0..<imageCount where x < slices.count {
            if slices.rois(at: x).contains(where: { $0 === roi }) { return Int32(x) }
        }
        return -1
    }

    /// Merges the brush ROIs of `rois` into the last of them, announcing and
    /// then removing each of the others.
    static func merge(_ rois: [Any], remove: (ROI) -> Void) {
        let brushes = rois.compactMap { $0 as? ROI }
        guard let plan = BrushROIOperations.mergePlan(isBrush: brushes.map { $0.type == .tPlain }) else { return }
        let target = brushes[plan.target]

        for index in plan.merged {
            target.merge(withTexture: brushes[index])
        }

        for index in plan.merged {
            ViewerROIEdits.post(.OsirixRemoveROI, brushes[index])
            remove(brushes[index])
        }
    }

    /// Turns the ROIs the "apply to" window chooses into brushes, or the
    /// brushes into polygons of 100 points, as one undo step.
    static func convertBrushPolygon(in viewer: ViewerController) {
        viewer.add(toUndoQueue: "roi")
        viewer.horos_imageView?.stopROIEditingForce(true)

        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            viewer.saveROI(movie)
        }

        let selectedROIs = viewer.roiApplyWindow(viewer) as? [Any] ?? []
        let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex))

        for case let selectedROI as ROI in selectedROIs {
            let index = Int(viewer.imageIndexOfROI(selectedROI))
            guard index >= 0 else { continue }

            let newROI = selectedROI.type == .tPlain
                ? viewer.convertBrushROItoPolygon(selectedROI, numPoints: 100)
                : viewer.convertPolygonROItoBrush(selectedROI)
            guard let newROI else { continue }

            // Add the new ROI
            selectedROI.curView?.roiSet(newROI)
            slices?.list(at: index)?.add(newROI)
            newROI.roImode = Int(ROI_selected)
            newROI.name = selectedROI.name
            newROI.comments = selectedROI.comments

            // Remove the old ROI
            ViewerROIEdits.post(.OsirixRemoveROI, selectedROI)
            slices?.list(at: index)?.remove(selectedROI)
        }

        if let view = viewer.horos_imageView {
            view.setIndex(view.curImage)
        }
    }
}
