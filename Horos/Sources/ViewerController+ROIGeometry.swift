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

// The constructions of the 2D viewer on its line and point ROIs. The
// selectors stay on ViewerController (-generateGeometryFromSelectedLine:,
// -measureBetweenSelectedSlices:, and -horosPickInterslicePreferred:first:
// second:, which the menu validation calls) as façades; the work is
// ViewerROILineConstruction's and ViewerIntersliceMeasure's, which receive the
// viewer as an argument and never keep it. The parallel, perpendicular and
// midpoint of a line are ROILineGeometry's; the measure between two points on
// different slices ROIIntersliceGeometry's; which two points it joins is
// IsiXROI's (ROIIntersliceSelection).

public extension ViewerController {

    /// Adds to the current image the parallel, the perpendicular and the
    /// midpoint of a line ROI (the one a contextual menu was opened on, or the
    /// first selected line), grouped with it.
    @objc(generateGeometryFromSelectedLine:)
    @IBAction func generateGeometryFromSelectedLine(_ sender: Any!) {
        ViewerROILineConstruction.add(from: sender, in: self)
    }

    /// The 2D points of this viewer, of the viewer blended with it (or that
    /// it is blended in) and of its registered viewer: {roi, pix, slice,
    /// viewer} each, unlocked ones only.
    @objc(horosInterslicePointRecords)
    func horosInterslicePointRecords() -> [NSDictionary] {
        ViewerIntersliceMeasure.points(of: self).map(\.record)
    }

    /// The two 2D points to measure between, the `preferred` ROI's first
    /// when it has a partner (ROIIntersliceSelection). NO when there are none.
    @objc(horosPickInterslicePreferred:first:second:)
    func horosPickInterslicePreferred(_ preferred: ROI?, first: AutoreleasingUnsafeMutablePointer<NSDictionary?>?,
                                      second: AutoreleasingUnsafeMutablePointer<NSDictionary?>?) -> Bool {
        guard let pair = ViewerIntersliceMeasure.pair(in: self, preferred: preferred) else { return false }
        first?.pointee = pair.first.record
        second?.pointee = pair.second.record
        return true
    }

    /// The point of a record ({roi, pix}) in the patient's space, at the
    /// centre of its pixel.
    @objc(horosSlicePointFromRecord:)
    func horosSlicePoint(fromRecord record: NSDictionary!) -> ROISlicePoint! {
        ViewerIntersliceMeasure.slicePoint(roi: record?.object(forKey: "roi") as? ROI, pix: record?.object(forKey: "pix") as? DCMPix)
    }

    /// Adds to the current image a text ROI with the distance between two
    /// 2D points on different slices (projected and in 3D) and their
    /// orientation, grouped with them.
    @objc(measureBetweenSelectedSlices:)
    @IBAction func measureBetweenSelectedSlices(_ sender: Any!) {
        ViewerIntersliceMeasure.add(from: sender, in: self)
    }
}

/// Adds the new ROIs of a construction to the image shown, each announced,
/// and draws it again.
@MainActor fileprivate func addToShownImage(_ rois: [ROI?], of viewer: ViewerController) {
    let list = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex))?.list(at: Int(viewer.horos_imageView?.curImage ?? 0))
    if let list { for roi in rois { viewerArrayAdd(roi, to: list) } }
    for roi in rois {
        ViewerROIEdits.post(.OsirixROIChange, roi)
    }
    viewer.horos_imageView?.needsDisplay = true
}

/// The ROI a contextual menu item was opened on, if `sender` is one.
@MainActor fileprivate func menuROI(_ sender: Any?) -> ROI? {
    (sender as? NSMenuItem)?.representedObject as? ROI
}

// MARK: - Line constructions

/// The parallel, the perpendicular and the midpoint of a line ROI.
@MainActor enum ViewerROILineConstruction {

    /// Adds the constructions of the line `sender` was opened on, or of the
    /// first selected line, grouped with it, as one undo step.
    static func add(from sender: Any?, in viewer: ViewerController) {
        var source = menuROI(sender)
        if source == nil {
            for case let roi as ROI in viewer.selectedROIs() ?? [] where roi.type == .tMesure && (roi.points?.count ?? 0) >= 2 {
                source = roi
                break
            }
        }
        guard let source, source.type == .tMesure, (source.points?.count ?? 0) >= 2, !source.locked else { return }

        guard let geometry = ROILineGeometry.construction(from: source.point(at: 0), b: source.point(at: 1),
                                                          spacingX: source.pixelSpacingX, spacingY: source.pixelSpacingY) else { return }

        viewer.add(toUndoQueue: "roi")

        let groupID = source.groupID > 0 ? source.groupID : Date.timeIntervalSinceReferenceDate
        source.groupID = groupID

        func styled(_ roi: ROI?, _ name: String) {
            roi?.name = name
            roi?.thickness = source.thickness
            roi?.opacity = source.opacity
            roi?.rgbcolor = source.rgbcolor
            roi?.groupID = groupID
        }

        let parallel = viewer.horosMakeROI(.tMesure)
        parallel?.addPoint(geometry.parallelA)
        parallel?.addPoint(geometry.parallelB)
        styled(parallel, NSLocalizedString("Parallel", comment: ""))

        let perpendicular = viewer.horosMakeROI(.tMesure)
        perpendicular?.addPoint(geometry.perpendicularA)
        perpendicular?.addPoint(geometry.perpendicularB)
        styled(perpendicular, NSLocalizedString("Perpendicular", comment: ""))

        let midpoint = viewer.horosMakeROI(.t2DPoint)
        midpoint?.rect = NSRect(x: geometry.midpoint.x, y: geometry.midpoint.y, width: 0, height: 0)
        styled(midpoint, NSLocalizedString("Midpoint", comment: ""))

        addToShownImage([parallel, perpendicular, midpoint], of: viewer)
    }
}

// MARK: - Measure between slices

/// A 2D point a measure between slices can join: its ROI, the image it is
/// on, its index there and its viewer.
@MainActor struct ViewerIntersliceRecord {
    let roi: ROI
    let pix: Any
    let slice: Int
    let viewer: ViewerController

    /// The record as the menu validation and the measure have it: {roi, pix, slice, viewer}.
    var record: NSDictionary {
        NSDictionary(objects: [roi, pix, NSNumber(value: UInt(slice)), viewer],
                     forKeys: ["roi" as NSString, "pix" as NSString, "slice" as NSString, "viewer" as NSString])
    }
}

/// The measure between two 2D points on different slices.
@MainActor enum ViewerIntersliceMeasure {

    /// The unlocked 2D points of `viewer`, of the viewer blended with it (or
    /// that it is blended in) and of its registered viewer.
    static func points(of viewer: ViewerController) -> [ViewerIntersliceRecord] {
        var viewers: [ViewerController] = [viewer]
        if let blending = viewer.blending(), blending !== viewer {
            viewers.append(blending)
        } else if let blended = viewer.blendedWindow, blended !== viewer {
            viewers.append(blended)
        }
        if let registered = viewer.registeredViewer(), registered !== viewer, !viewers.contains(where: { $0 === registered }) {
            viewers.append(registered)
        }

        var records: [ViewerIntersliceRecord] = []
        for each in viewers {
            let slices = ViewerROISlices(each, movie: Int(each.horos_curMovieIndex))
            let pixs = each.horos_pixList(at: Int(each.horos_curMovieIndex)) ?? []
            for index in 0..<min(slices?.count ?? 0, pixs.count) {
                for roi in slices?.rois(at: index) ?? [] where roi.type == .t2DPoint && !roi.locked {
                    records.append(ViewerIntersliceRecord(roi: roi, pix: pixs[index], slice: index, viewer: each))
                }
            }
        }
        return records
    }

    /// The two points to measure between, the `preferred` ROI's first when
    /// it has a partner (ROIIntersliceSelection); nil when there are none.
    static func pair(in viewer: ViewerController, preferred: ROI?) -> (first: ViewerIntersliceRecord, second: ViewerIntersliceRecord)? {
        let records = points(of: viewer)
        let candidates = records.map { record in
            ROIIntersliceCandidate(roi: ObjectIdentifier(record.roi), viewer: ObjectIdentifier(record.viewer), slice: record.slice,
                                   isSelected: ROISelection.isSelected(record.roi.roImode))
        }
        guard let pair = ROIIntersliceSelection.pair(of: candidates, preferred: preferred.map { ObjectIdentifier($0) }) else { return nil }
        return (records[pair.first], records[pair.second])
    }

    /// The point of `roi` on `pix` in the patient's space, at the centre of its pixel.
    static func slicePoint(roi: ROI?, pix: DCMPix?) -> ROISlicePoint {
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

    /// Adds the measure between the two points `sender` (a contextual menu
    /// item opened on one of them) or the selection names, grouped with them,
    /// as one undo step.
    static func add(from sender: Any?, in viewer: ViewerController) {
        guard let found = pair(in: viewer, preferred: menuROI(sender)) else { return }
        let (first, second) = found

        guard let measure = ROIIntersliceGeometry.measure(from: slicePoint(roi: first.roi, pix: first.pix as? DCMPix),
                                                          to: slicePoint(roi: second.roi, pix: second.pix as? DCMPix)) else { return }

        viewer.add(toUndoQueue: "roi")

        var labelAt = first.roi.rect.origin
        if second.viewer === viewer, second.slice == Int(viewer.horos_imageView?.curImage ?? 0) {
            labelAt = second.roi.rect.origin
        }

        let note = viewer.horosMakeROI(.tText)
        note?.rect = NSRect(x: labelAt.x + 6, y: labelAt.y + 6, width: 0, height: 0)
        note?.name = String(format: NSLocalizedString("%.2f mm projection / %.2f mm 3D (%@)", comment: ""),
                            measure.projectedDistance, measure.distance3D, measure.orientation)
        note?.comments = measure.summary

        let groupID = Date.timeIntervalSinceReferenceDate
        if first.roi.groupID == 0 { first.roi.groupID = groupID }
        if second.roi.groupID == 0 { second.roi.groupID = first.roi.groupID }
        note?.groupID = first.roi.groupID

        addToShownImage([note], of: viewer)
    }
}
