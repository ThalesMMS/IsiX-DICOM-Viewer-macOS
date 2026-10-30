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

// The constructions of the 2D viewer on its line and point ROIs are
// implemented in Swift: a Swift extension of ViewerController, which stays
// Objective-C, with the same selectors (-generateGeometryFromSelectedLine:,
// -measureBetweenSelectedSlices:, and -horosPickInterslicePreferred:first:
// second:, which the menu validation calls). The parallel, perpendicular and
// midpoint of a line are ROILineGeometry's; the measure between two points
// on different slices ROIIntersliceGeometry's; which two points it joins is
// IsiXROI's (ROIIntersliceSelection).

public extension ViewerController {

    /// Adds to the current image the parallel, the perpendicular and the
    /// midpoint of a line ROI (the one a contextual menu was opened on, or the
    /// first selected line), grouped with it.
    @objc(generateGeometryFromSelectedLine:)
    @IBAction func generateGeometryFromSelectedLine(_ sender: Any!) {
        var source: ROI? = nil
        if let item = sender as? NSMenuItem, let roi = item.representedObject as? ROI {
            source = roi
        }
        if source == nil {
            for case let roi as ROI in selectedROIs() ?? NSMutableArray() {
                if roi.type == .tMesure && (roi.points?.count ?? 0) >= 2 {
                    source = roi
                    break
                }
            }
        }
        guard let source, source.type == .tMesure, (source.points?.count ?? 0) >= 2, !source.locked else { return }

        guard let geometry = ROILineGeometry.construction(from: source.point(at: 0), b: source.point(at: 1),
                                                          spacingX: source.pixelSpacingX, spacingY: source.pixelSpacingY) else { return }

        add(toUndoQueue: "roi")

        let groupID = source.groupID > 0 ? source.groupID : Date.timeIntervalSinceReferenceDate
        source.groupID = groupID

        func styled(_ roi: ROI?, _ name: String) {
            roi?.name = name
            roi?.thickness = source.thickness
            roi?.opacity = source.opacity
            roi?.rgbcolor = source.rgbcolor
            roi?.groupID = groupID
        }

        let parallel = horosMakeROI(.tMesure)
        parallel?.addPoint(geometry.parallelA)
        parallel?.addPoint(geometry.parallelB)
        styled(parallel, NSLocalizedString("Parallel", comment: ""))

        let perpendicular = horosMakeROI(.tMesure)
        perpendicular?.addPoint(geometry.perpendicularA)
        perpendicular?.addPoint(geometry.perpendicularB)
        styled(perpendicular, NSLocalizedString("Perpendicular", comment: ""))

        let midpoint = horosMakeROI(.t2DPoint)
        midpoint?.rect = NSRect(x: geometry.midpoint.x, y: geometry.midpoint.y, width: 0, height: 0)
        styled(midpoint, NSLocalizedString("Midpoint", comment: ""))

        let list = horos_roiList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSMutableArray
        if let list { for roi in [parallel, perpendicular, midpoint] { viewerArrayAdd(roi, to: list) } }
        for roi in [parallel, perpendicular, midpoint] {
            NotificationCenter.default.post(name: .OsirixROIChange, object: roi, userInfo: nil)
        }
        horos_imageView?.needsDisplay = true
    }

    /// The 2D points of this viewer, of the viewer blended with it (or that
    /// it is blended in) and of its registered viewer: {roi, pix, slice,
    /// viewer} each, unlocked ones only.
    @objc(horosInterslicePointRecords)
    func horosInterslicePointRecords() -> [NSDictionary] {
        var records: [NSDictionary] = []
        var viewers: [ViewerController] = [self]
        if let blending = blending(), blending !== self {
            viewers.append(blending)
        } else if let blended = blendedWindow, blended !== self {
            viewers.append(blended)
        }
        if let registered = registeredViewer(), registered !== self, !viewers.contains(where: { $0 === registered }) {
            viewers.append(registered)
        }

        for viewer in viewers {
            let rois = viewer.roiList() ?? NSMutableArray()
            let pixs = viewer.pixList() ?? NSMutableArray()
            let count = min(rois.count, pixs.count)
            for i in 0 ..< count {
                let pix = pixs.object(at: i)
                for case let roi as ROI in (rois.object(at: i) as? NSArray) ?? NSArray() {
                    if roi.type != .t2DPoint || roi.locked { continue }
                    records.append(NSDictionary(objects: [roi, pix, NSNumber(value: UInt(i)), viewer],
                                                forKeys: ["roi" as NSString, "pix" as NSString, "slice" as NSString, "viewer" as NSString]))
                }
            }
        }
        return records
    }

    /// The two 2D points to measure between, the `preferred` ROI's first
    /// when it has a partner (ROIIntersliceSelection). NO when there are none.
    @objc(horosPickInterslicePreferred:first:second:)
    func horosPickInterslicePreferred(_ preferred: ROI?, first: AutoreleasingUnsafeMutablePointer<NSDictionary?>?,
                                      second: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> Bool {
        let records = horosInterslicePointRecords()
        let candidates = records.map { record -> ROIIntersliceCandidate in
            let roi = record.object(forKey: "roi") as! ROI
            let mode = roi.roImode
            return ROIIntersliceCandidate(roi: ObjectIdentifier(roi), viewer: ObjectIdentifier(record.object(forKey: "viewer") as AnyObject),
                                          slice: (record.object(forKey: "slice") as! NSNumber).intValue,
                                          isSelected: mode == Int(ROI_selected) || mode == Int(ROI_selectedModify) || mode == Int(ROI_drawing))
        }
        guard let pair = ROIIntersliceSelection.pair(of: candidates, preferred: preferred.map { ObjectIdentifier($0) }) else { return false }
        first?.pointee = records[pair.first]
        second?.pointee = records[pair.second]
        return true
    }

    /// The point of a record ({roi, pix}) in the patient's space, at the
    /// centre of its pixel.
    @objc(horosSlicePointFromRecord:)
    func horosSlicePoint(fromRecord record: NSDictionary!) -> ROISlicePoint! {
        let roi = record.object(forKey: "roi") as? ROI
        let pix = record.object(forKey: "pix") as? DCMPix
        var orientation = [Float](repeating: 0, count: 9)
        pix?.orientation(&orientation)
        let pixel = roi?.rect.origin ?? .zero
        return ROISlicePoint(pixelX: Double(pixel.x), pixelY: Double(pixel.y),
                             originX: pix?.originX ?? 0, originY: pix?.originY ?? 0, originZ: pix?.originZ ?? 0,
                             rowX: Double(orientation[0]), rowY: Double(orientation[1]), rowZ: Double(orientation[2]),
                             colX: Double(orientation[3]), colY: Double(orientation[4]), colZ: Double(orientation[5]),
                             normalX: Double(orientation[6]), normalY: Double(orientation[7]), normalZ: Double(orientation[8]),
                             spacingX: pix?.pixelSpacingX ?? 0, spacingY: pix?.pixelSpacingY ?? 0,
                             pixelCenter: true)
    }

    /// Adds to the current image a text ROI with the distance between two
    /// 2D points on different slices (projected and in 3D) and their
    /// orientation, grouped with them.
    @objc(measureBetweenSelectedSlices:)
    @IBAction func measureBetweenSelectedSlices(_ sender: Any!) {
        var preferred: ROI? = nil
        if let item = sender as? NSMenuItem, let roi = item.representedObject as? ROI {
            preferred = roi
        }

        var first: NSDictionary? = nil
        var second: NSDictionary? = nil
        guard horosPickInterslicePreferred(preferred, first: &first, second: &second), let first, let second else { return }

        guard let measure = ROIIntersliceGeometry.measure(from: horosSlicePoint(fromRecord: first), to: horosSlicePoint(fromRecord: second)) else { return }

        add(toUndoQueue: "roi")

        var labelAt = (first.object(forKey: "roi") as? ROI)?.rect.origin ?? .zero
        if (second.object(forKey: "viewer") as AnyObject?) === self,
           (second.object(forKey: "slice") as? NSNumber)?.intValue == Int(horos_imageView?.curImage ?? 0) {
            labelAt = (second.object(forKey: "roi") as? ROI)?.rect.origin ?? .zero
        }

        let note = horosMakeROI(.tText)
        note?.rect = NSRect(x: labelAt.x + 6, y: labelAt.y + 6, width: 0, height: 0)
        note?.name = String(format: NSLocalizedString("%.2f mm projection / %.2f mm 3D (%@)", comment: ""),
                            measure.projectedDistance, measure.distance3D, measure.orientation)
        note?.comments = measure.summary

        let groupID = Date.timeIntervalSinceReferenceDate
        let firstROI = first.object(forKey: "roi") as? ROI
        let secondROI = second.object(forKey: "roi") as? ROI
        if firstROI?.groupID == 0 { firstROI?.groupID = groupID }
        if secondROI?.groupID == 0 { secondROI?.groupID = firstROI?.groupID ?? 0 }
        note?.groupID = firstROI?.groupID ?? 0

        let list = horos_roiList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSMutableArray
        if let list { viewerArrayAdd(note, to: list) }
        NotificationCenter.default.post(name: .OsirixROIChange, object: note, userInfo: nil)
        horos_imageView?.needsDisplay = true
    }
}
