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

// The brush ROIs of the 2D viewer are implemented in Swift: a Swift
// extension of ViewerController, which stays Objective-C, with the same
// selectors (the morphology filters, -applyMorphology:action:radius:
// sendNotification:, the conversions between brush and polygon ROIs, the
// merge of brushes, -imageIndexOfROI:). The filter a menu item asks for and
// the resampling of a brush contour into polygon points are IsiXROI's
// (ROIBrushMorphology, ROIContourResampling).

/// `[NSDictionary dictionaryWithObjectsAndKeys: …]`: the pairs up to the
/// first nil object.
fileprivate func dictionaryOfPairs(_ pairs: [(Any?, String)]) -> NSDictionary {
    let dictionary = NSMutableDictionary()
    for (object, key) in pairs {
        guard let object else { break }
        dictionary.setObject(object, forKey: key as NSString)
    }
    return dictionary.copy() as! NSDictionary
}

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
        NSLog("****** applyMorphology - START")

        horos_roiLock?.lock()

        var filter: ITKBrushROIFilter? = nil

        if let exception = viewerObjCTry({
            filter = ITKBrushROIFilter()

            let queue = OperationQueue()

            for roi in rois ?? [] {
                let op = ViewerControllerOperation(controller: self, dict: dictionaryOfPairs([
                    (roi, "roi"), (action, "action"), (filter, "filter"), (NSNumber(value: Int32(truncatingIfNeeded: radius)), "radius")]))
                queue.addOperation(op)
            }

            queue.waitUntilAllOperationsAreFinished()
        }) {
            _N2LogExceptionImpl(exception, true, "-[ViewerController applyMorphology:action:radius:sendNotification:]")
        }

        horos_roiLock?.unlock()

        if sendNotification {
            for roi in rois ?? [] {
                NotificationCenter.default.post(name: .OsirixROIChange, object: roi, userInfo: nil)
            }
        }

        filter = nil

        NSLog("****** applyMorphology - END")
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
        horos_brushROIFilterOptionsWindow?.orderOutAndEndSheet()

        if ViewerSender.tag(sender) != 0 {
            let selectedROI = selectedROI()

            let wait = WaitRendering(NSLocalizedString("Processing...", comment: ""))
            wait?.showWindow(self)
            let radius = Int(horos_structuringElementRadiusSlider?.intValue ?? 0)
            if (horos_brushROIFilterOptionsAllWithSameName?.state ?? .off) == .off {
                guard let selectedROI else {
                    // [NSArray arrayWithObject: nil], as the Objective-C sent it.
                    NSException(name: .invalidArgumentException,
                                reason: "*** -[NSArray initWithObjects:count:]: attempt to insert nil object from objects[0]", userInfo: nil).raise()
                    return
                }
                applyMorphology([selectedROI], action: horos_morphoFunction, radius: radius, sendNotification: true)
            } else {
                applyMorphology(rois(withName: selectedROI?.name, in4D: true) as? [Any], action: horos_morphoFunction,
                                radius: radius, sendNotification: true)
            }
            wait?.close()
        }
    }

    /// Chooses the filter of the menu item (tag 0 erode, 1 dilate, 2 close,
    /// 3 open) and asks for its radius, for a selected brush ROI.
    @objc(morphoSelectedBrushROI:)
    @IBAction func morphoSelectedBrushROI(_ sender: Any!) {
        horosLoadViewerPanels()

        let selectedROI = selectedROI()

        horos_morphoFunction = ROIBrushMorphology.action(forTag: ViewerSender.tag(sender))

        if let selectedROI, selectedROI.type == .tPlain {
            add(toUndoQueue: "roi")

            if let options = horos_brushROIFilterOptionsWindow {
                window?.beginSheet(options, completionHandler: nil)
            }
        } else {
            _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Brush ROI Error", comment: ""),
                                            message: NSLocalizedString("Select a Brush ROI before to run the filter.", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
    }

    /// A brush ROI of the area of a closed or open polygon, a pencil or an
    /// oval ROI (which becomes a closed polygon), nil when it is empty.
    @objc(convertPolygonROItoBrush:)
    func convertPolygonROItoBrush(_ selectedROI: ROI!) -> ROI! {
        var theNewROI: ROI? = nil

        if selectedROI.type == .tOval {
            let points = selectedROI.points
            selectedROI.type = .tCPolygon
            selectedROI.points = points
        }

        if selectedROI.type == .tCPolygon || selectedROI.type == .tOPolygon || selectedROI.type == .tPencil {
            var s = NSSize.zero
            var o = NSPoint.zero
            if let texture = DCMPix.mapFromPolygonROI(selectedROI, size: &s, origin: &o) {
                let pix = horos_imageView?.curDCM
                theNewROI = ROI(texture: texture, textWidth: Int32(s.width), textHeight: Int32(s.height), textName: "",
                                positionX: Int32(o.x), positionY: Int32(o.y),
                                spacingX: Float(pix?.pixelSpacingX ?? 0), spacingY: Float(pix?.pixelSpacingY ?? 0),
                                imageOrigin: NSPoint(x: pix?.originX ?? 0, y: pix?.originY ?? 0))
                if theNewROI?.reduceTextureIfPossible() == false {
                    // NO means that the ROI is NOT empty.
                } else {
                    theNewROI = nil
                }

                free(texture)
            }
        }

        return theNewROI
    }

    /// A closed polygon of `numPoints` points along the contour of a brush ROI.
    @objc(convertBrushROItoPolygon:numPoints:)
    func convertBrushROItoPolygon(_ selectedROI: ROI!, numPoints: Int32) -> ROI! {
        var newROI: ROI? = nil

        if selectedROI.type == .tPlain {
            newROI = horosMakeROI(.tCPolygon)

            let points: NSArray = ITKSegmentation3D.extractContour(selectedROI.textureBuffer, width: Int(selectedROI.textureWidth),
                                                                   height: Int(selectedROI.textureHeight), numPoints: Int(numPoints)) ?? NSMutableArray()

            for case let point as MyPoint in points {
                point.move(Float(selectedROI.textureUpLeftCornerX), Float(selectedROI.textureUpLeftCornerY))
            }

            let pts = NSMutableArray()
            for sample in ROIContourResampling.samples(contourCount: points.count, numPoints: Int(numPoints)) {
                let a = points.object(at: sample.from) as! MyPoint
                let b = points.object(at: sample.to) as! MyPoint
                pts.add(MyPoint.point(ROI.pointBetweenPoint(a.point, and: b.point, ratio: sample.ratio)))
            }

            newROI?.points = pts
        }

        return newROI
    }

    /// The index of the image of the current time point whose list holds
    /// `c`, -1 when none does.
    @objc(imageIndexOfROI:)
    func imageIndexOfROI(_ c: ROI!) -> Int32 {
        let rois = horos_roiList(at: Int(horos_curMovieIndex))
        var x = 0
        while x < (horos_pixList(at: Int(horos_curMovieIndex))?.count ?? 0) {
            let list = rois?.object(at: x) as? NSArray
            var i = 0
            while i < (list?.count ?? 0) {
                if (list?.object(at: i) as AnyObject?) === c { return Int32(x) }
                i += 1
            }
            x += 1
        }
        return -1
    }

    /// Merges the brush ROIs of `s` into the last of them, removing the
    /// others from `roiListContained`.
    @objc(mergeBrushROI:ROIs:ROIList:)
    func mergeBrushROI(_ sender: Any!, rois s: [Any]!, roiList roiListContained: NSMutableArray!) {
        guard let s, !s.isEmpty else { return }
        var rois: [ROI] = []
        for case let r as ROI in s where r.type == .tPlain { rois.append(r) }
        guard let f = rois.popLast() else { return }

        for r in rois {
            f.merge(withTexture: r)
        }

        for r in rois {
            NotificationCenter.default.post(name: .OsirixRemoveROI, object: r, userInfo: nil)
            roiListContained?.remove(r)
        }
    }

    /// Merges the selected brush ROIs of the current image.
    @objc(mergeBrushROI:)
    @IBAction func mergeBrushROI(_ sender: Any!) {
        mergeBrushROI(sender, rois: selectedROIs() as? [Any],
                      roiList: horos_roiList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSMutableArray)
    }

    /// Turns the ROIs the "apply to" window chooses into brushes, or the
    /// brushes into polygons of 100 points.
    @objc(convertBrushPolygon:)
    @IBAction func convertBrushPolygon(_ sender: Any!) {
        add(toUndoQueue: "roi")
        horos_imageView?.stopROIEditingForce(true)

        var i = 0
        while i < Int(horos_maxMovieIndex) {
            saveROI(i)
            i += 1
        }

        let selectedROIs = (roiApplyWindow(self) as NSArray?) ?? NSArray()

        for case let selectedROI as ROI in selectedROIs {
            let index = Int(imageIndexOfROI(selectedROI))

            if index >= 0 {
                let newROI = selectedROI.type == .tPlain ? convertBrushROItoPolygon(selectedROI, numPoints: 100) : convertPolygonROItoBrush(selectedROI)

                if let newROI {
                    // Add the new ROI
                    selectedROI.curView?.roiSet(newROI)
                    (horos_roiList(at: Int(horos_curMovieIndex))?.object(at: index) as? NSMutableArray)?.add(newROI)
                    newROI.roImode = Int(ROI_selected)
                    newROI.name = selectedROI.name
                    newROI.comments = selectedROI.comments

                    // Remove the old ROI
                    NotificationCenter.default.post(name: .OsirixRemoveROI, object: selectedROI, userInfo: nil)
                    (horos_roiList(at: Int(horos_curMovieIndex))?.object(at: index) as? NSMutableArray)?.remove(selectedROI)
                }
            }
        }

        if let view = horos_imageView {
            view.setIndex(view.curImage)
        }
    }
}
