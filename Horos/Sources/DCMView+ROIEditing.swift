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
import IsiXImaging
import IsiXPreferences
import IsiXROI
import UniformTypeIdentifiers

// The ROI editing and the clipboard of DCMView are implemented in Swift: an
// extension of DCMView, with the same selectors. Stopping the
// edition of a ROI, the ROIs saved to and loaded from .roi and XML files,
// copy, cut and paste, undo and redo, the removal of ROIs and of their groups,
// the join of a finished contour to the ROI of a neighbouring image, select
// all, the ROI thickness and the menu validation. -validateMenuItem:
// (DCMView+Viewer.swift), which MPRDCMView overrides, calls
// -horosValidateMenuItem: here. The rules without the view are in IsiXROI
// (ROIEditing, ROIEditingSession), and the notifications go through
// ROIEventEmitter.

/// N2LogExceptionWithStackTrace(e) (or N2LogException(e) when `stack` is
/// false) in `function`.
private func logROIEditingException(_ exception: NSException, _ function: StaticString, stack: Bool = true) {
    function.withUTF8Buffer { buffer in
        buffer.withMemoryRebound(to: CChar.self) { _N2LogExceptionImpl(exception, stack, $0.baseAddress) }
    }
}

private let roiObjectType = NSPasteboard.PasteboardType("ROIObject")

extension DCMView {

    private var roiEditingViewer: ViewerController? { self.windowController() as? ViewerController }

    /// Sends `selector` with `argument` to the window controller, whatever its
    /// class, as the Objective-C sent it.
    private func sendToWindowController(_ selector: String, _ argument: Any?) {
        _ = (self.windowController() as? NSObject)?.perform(NSSelectorFromString(selector), with: argument)
    }

    /// With "markROIImageAsKeyImage", the image of a ROI added in a 2D viewer
    /// becomes a key image.
    private func markROIImageAsKeyImageIfAsked() {
        if ViewROIEditing.marksROIImageAsKeyImage {
            if self.is2DViewer() && !self.isKeyImage(), let viewer = roiEditingViewer, !viewer.isPostprocessed() {
                viewer.setKeyImage(self)
            }
        }
    }

    // MARK: - Editing

    @objc(stopROIEditingForce:)
    public dynamic func stopROIEditingForce(_ force: Bool) {
        self.horos_drawingROI = false
        let current = self.horos_curROI
        for case let r as ROI in self.horos_curRoiList ?? [] where current !== r {
            let mode = ROIEditingSession.modeWhenStopped(r.roImode)
            if mode != r.roImode {
                r.roImode = mode
            }
        }

        if let current {
            // Does this ROI have alias in other views?
            let stop = ROIEditingSession.stopping(mode: current.roImode, force: force) {
                (self.horos_dcmRoiList as? [Any] ?? []).filter { ViewROIEditing.rois($0).contains { $0 === current } }.count
            }
            if case .ends(let checksValidity) = stop {
                current.roImode = Int(ROI_selected)

                if checksValidity && !current.valid() {
                    ROIEventEmitter.willRemove(current)
                    _ = HorosObjCException.caught { self.horos_curRoiList?.remove(current) }
                    ROIEventEmitter.removedFromList()
                }

                self.horos_curROI = nil
            }
        }

        if self.showDescriptionInLarge {
            self.showDescriptionInLarge = false
            self.switchShowDescriptionInLarge()
        }
    }

    @objc(stopROIEditing)
    public dynamic func stopROIEditing() {
        self.stopROIEditingForce(false)
    }

    @objc(roiSet:)
    public dynamic func roiSet(_ aRoi: ROI!) {
        aRoi?.curView = self
    }

    @objc(roiSet)
    public dynamic func roiSet() {
        for case let c as ROI in self.horos_curRoiList ?? [] {
            c.curView = self
        }
    }

    @objc(selectAll:)
    @IBAction public override dynamic func selectAll(_ sender: Any?) {
        for case let r as ROI in self.horos_curRoiList ?? [] {
            r.roImode = Int(ROI_selected)
            ROIEventEmitter.selected(r)
        }
        self.needsDisplay = true
    }

    @objc(decreaseThickness:)
    @IBAction public dynamic func decreaseThickness(_ sender: Any!) {
        for case let r as ROI in self.horos_curRoiList ?? [] where r.roImode == Int(ROI_selected) {
            r.thickness = r.thickness - 1
        }
        self.display()
    }

    @objc(increaseThickness:)
    @IBAction public dynamic func increaseThickness(_ sender: Any!) {
        for case let r as ROI in self.horos_curRoiList ?? [] where r.roImode == Int(ROI_selected) {
            r.thickness = r.thickness + 1
        }
        self.display()
    }

    // MARK: - Menu validation

    /// What DCMView's -validateMenuItem: answers.
    @objc(horosValidateMenuItem:)
    public dynamic func horosValidateMenuItem(_ item: NSMenuItem!) -> Bool {
        var valid = false
        let action = item.action

        if action == NSSelectorFromString("roiSaveSelected:") || action == NSSelectorFromString("increaseThickness:")
            || action == NSSelectorFromString("decreaseThickness:") {
            for case let r as ROI in self.horos_curRoiList ?? [] where r.roImode == Int(ROI_selected) {
                valid = true
            }
        } else if action == NSSelectorFromString("copy:") && item.tag == 1 { // copy all viewers
            if ViewerController.numberOf2DViewer() > 1 {
                valid = true
            }
        } else if action == NSSelectorFromString("switchCopySettingsInSeries:") {
            valid = true
            item.state = NSControl.StateValue(rawValue: self.horos_COPYSETTINGSINSERIES ? 1 : 0)
        } else if action == NSSelectorFromString("flipHorizontal:") {
            valid = true
            item.state = NSControl.StateValue(rawValue: self.horos_xFlipped ? 1 : 0)
        } else if action == NSSelectorFromString("flipVertical:") {
            valid = true
            item.state = NSControl.StateValue(rawValue: self.horos_yFlipped ? 1 : 0)
        } else if action == NSSelectorFromString("syncronize:") {
            valid = true
            item.state = item.tag == Int(SliceSyncSettings.mode) ? .on : .off
        } else if action == NSSelectorFromString("mergeFusedImages:") {
            if self.horos_blending != nil {
                valid = true
            }
        } else if action == NSSelectorFromString("annotMenu:") {
            valid = true
            item.state = item.tag == PreferencesSource.process.preferences[ViewerPreferences.annotations] ? .on : .off
        } else if action == NSSelectorFromString("barMenu:") {
            valid = true
            item.state = item.tag == PreferencesSource.process.preferences[ViewerPreferences.clutBars] ? .on : .off
        } else if action == NSSelectorFromString("increaseFontSize:") || action == NSSelectorFromString("decreaseFontSize:") {
            valid = DCMView.labelFontSizeMenuItemIsEnabled(item)
        } else {
            valid = true
        }

        if self.showDescriptionInLarge {
            self.showDescriptionInLarge = false
            self.switchShowDescriptionInLarge()
        }

        return valid
    }

    // MARK: - Files

    @objc(roiLoadFromFilesArray:)
    public dynamic func roiLoad(fromFilesArray filenames: [Any]!) {
        // Unselect all ROIs
        for case let r as ROI in self.horos_curRoiList ?? [] {
            r.roImode = Int(ROI_sleep)
        }

        for case let path as String in filenames ?? [] {
            let roiArray = RestrictedUnarchiver.unarchiveROIs(withFile: path)

            for case let item as ROI in roiArray ?? [] {
                let pix = self.curDCM
                item.setOriginAndSpacing(Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0), DCMPix.originCorrected(accordingToOrientation: pix))
                item.roImode = Int(ROI_selected)
                item.curView = self

                ROIEventEmitter.selected(item)
            }

            markROIImageAsKeyImageIfAsked()

            if let roiArray {
                self.horos_curRoiList?.addObjects(from: roiArray as [AnyObject])
            }
        }

        self.needsDisplay = true
    }

    @objc(roiSaveSelected:)
    @IBAction public dynamic func roiSaveSelected(_ sender: Any!) {
        let panel = NSSavePanel()

        let selectedROIs = NSMutableArray()
        for case let r as ROI in self.horos_curRoiList ?? [] where r.roImode == Int(ROI_selected) {
            selectedROIs.add(r)
        }

        if selectedROIs.count > 0 {
            panel.canSelectHiddenExtension = false
            panel.allowedContentTypes = [UTType(filenameExtension: "roi")!]
            panel.nameFieldStringValue = (selectedROIs.object(at: 0) as? ROI)?.name ?? ""

            panel.begin { result in
                if result != .OK {
                    return
                }
                // Compatibility: .roi is a typedstream shared with released Horos/OsiriX.
                if let path = panel.url?.path {
                    _ = try? HistoricalArchive.archiveRootObject(selectedROIs, toFile: path)
                }
            }
        } else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Save Error", comment: ""),
                                        message: NSLocalizedString("No ROI(s) selected to save!", comment: ""),
                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }
    }

    @objc(roiLoadFromXML:)
    public dynamic func roiLoad(fromXML xml: [AnyHashable: Any]!) {
        let xml = xml ?? [:]

        // Single ROI
        if let slice = xml["Slice"] {
            let number = (slice as? NSNumber)?.int32Value ?? (slice as? NSString)?.intValue ?? 0
            self.setIndex(Int(truncatingIfNeeded: number - 1))

            if self.is2DViewer() {
                roiEditingViewer?.adjustSlider()
            }

            // SYNCRO
            self.sendSyncMessage(0)

            self.needsDisplay = true
        }

        let pointsStringArray = xml["ROIPoints"] as? [Any] ?? []

        let type: ToolMode
        switch ROIEditing.xmlShape(pointCount: pointsStringArray.count) {
        case .length: type = .tMesure
        case .point: type = .t2DPoint
        case .polygon: type = .tCPolygon
        }

        let pix = self.curDCM
        guard let roi = ROI(type: type, Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0),
                            DCMPix.originCorrected(accordingToOrientation: pix)) else { return }
        roi.name = xml["Name"] as? String
        roi.comments = xml["Comments"] as? String

        if type == .t2DPoint {
            var irect = NSRect.zero
            let point = NSPointFromString(pointsStringArray[0] as? String ?? "")
            irect.origin.x = point.x
            irect.origin.y = point.y
            roi.rect = irect
        }

        if pointsStringArray.count > 0 {
            let points = pointsStringArray.map { MyPoint.point(NSPointFromString($0 as? String ?? "")) }
            roi.points = NSMutableArray(array: points)
            roi.roImode = Int(ROI_selected)
            roi.curView = self
            markROIImageAsKeyImageIfAsked()

            self.horos_curRoiList?.add(roi)
            ROIEventEmitter.selected(roi)
        }
    }

    @objc(roiLoadFromXMLFiles:)
    @IBAction public dynamic func roiLoad(fromXMLFiles filenames: [Any]!) {
        if AnnotationLevel.revealROIs() {
            DCMView.setDefaults()
        }

        // Unselect all ROIs
        for case let r as ROI in self.horos_curRoiList ?? [] {
            r.roImode = Int(ROI_sleep)
        }

        for case let file as String in filenames ?? [] {
            let xml = ViewROIEditing.propertyList(atPath: file)
            if let roiArray = xml?["ROI array"] as? [Any] {
                for case let x as [AnyHashable: Any] in roiArray {
                    self.roiLoad(fromXML: x)
                }
            } else {
                self.roiLoad(fromXML: xml)
            }
        }

        self.needsDisplay = true
    }

    // MARK: - Undo

    @objc(undo:)
    public dynamic func undo(_ sender: Any!) {
        sendToWindowController("undo:", sender)
    }

    @objc(redo:)
    public dynamic func redo(_ sender: Any!) {
        sendToWindowController("redo:", sender)
    }

    // MARK: - Clipboard

    @objc(paste:)
    public dynamic func paste(_ sender: Any!) {
        let pb = NSPasteboard.general

        if let archivedData = pb.data(forType: roiObjectType) {
            sendToWindowController("addToUndoQueue:", "roi")

            let roiArray = RestrictedUnarchiver.unarchiveROIs(with: archivedData) ?? []

            // Unselect all ROIs
            for case let r as ROI in self.horos_curRoiList ?? [] {
                r.roImode = Int(ROI_sleep)
            }

            var planarROIs: [ROI] = []
            for case let r as ROI in roiArray {
                if let physical = r as? HorosVolumeLengthROI {
                    // A length through the volume goes to the series and frame of reference it was measured in.
                    let endpoint = self.lengthEndpoint(at: NSZeroPoint)
                    var payload = physical.volumeLength ?? [:]
                    if !ROIEditingSession.pastedLengthFits(series: payload["series"] as? String,
                                                           frameOfReference: payload["frameOfReference"] as? String,
                                                           imageSeries: endpoint?.object(forKey: "series") as? String,
                                                           imageFrameOfReference: endpoint?.object(forKey: "frameOfReference") as? String) {
                        NSSound.beep()
                        continue
                    }
                    payload["id"] = UUID().uuidString
                    payload["temporalIndex"] = endpoint?.object(forKey: "temporalIndex")
                    physical.volumeLength = payload
                    roiEditingViewer?.add(physical)
                    physical.roImode = Int(ROI_selected)
                    continue
                }
                planarROIs.append(r)
                r.isAliased = false

                // Correct the origin only if the orientation is the same
                r.pix = self.curDCM
                let pix = self.curDCM
                r.setOriginAndSpacing(Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0), DCMPix.originCorrected(accordingToOrientation: pix))

                r.roImode = Int(ROI_selected)
                r.curView = self
            }

            markROIImageAsKeyImageIfAsked()

            self.horos_curRoiList?.addObjects(from: planarROIs)

            for case let roi as ROI in roiArray {
                ROIEventEmitter.added(roi, to: self, slice: Int32(self.horos_curImage))
            }

            for case let roi as ROI in roiArray {
                ROIEventEmitter.selected(roi)
            }

            self.needsDisplay = true
        }

        if let controller = self.windowController() as? NSObject, controller.responds(to: NSSelectorFromString("paste:")) {
            controller.perform(NSSelectorFromString("paste:"), with: sender)
        }
    }

    @objc(copy:)
    @IBAction public dynamic func copy(_ sender: Any!) {
        let pb = NSPasteboard.general
        var roiSelected = false
        let roiSelectedArray = NSMutableArray()

        for case let r as ROI in self.horos_curRoiList ?? [] where r.roImode == Int(ROI_selected) {
            roiSelected = true
            roiSelectedArray.add(r)
        }

        let tag = (sender as AnyObject?)?.tag ?? 0
        if !roiSelected || tag != 0 {
            pb.declareTypes([.tiff], owner: self)

            DCMView.horosResetCaptureFailure()
            let im = self.nsimage(false, allViewers: tag != 0)

            // A capture that fails leaves a black picture: it is not what was asked for.
            if let reason = DCMView.horosCaptureFailure() {
                pb.clearContents()
                HorosAlertPanel.runCritical(title: NSLocalizedString("Copy", comment: ""),
                                            message: String(format: NSLocalizedString("The image could not be captured, so no black image was written or copied in its place.\n\n%@", comment: ""), reason),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                return
            }

            let jpeg = im?.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
                .representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: Float(0.9))])
            pb.setData(jpeg, forType: .tiff)
        } else {
            pb.declareTypes([roiObjectType, .string], owner: nil)
            // Compatibility: ROIObject is the released Horos/OsiriX typedstream pasteboard contract.
            pb.setData(try? HistoricalArchive.archivedData(withRootObject: roiSelectedArray), forType: roiObjectType)

            let descriptions = roiSelectedArray.map { ($0 as? NSObject)?.description ?? "" }
            pb.setString(ROIEditing.clipboardText(descriptions), forType: .string)
        }
    }

    @objc(cut:)
    @IBAction public dynamic func cut(_ sender: Any!) {
        self.copy(sender)

        var removed = false

        sendToWindowController("addToUndoQueue:", "roi")

        let drawLock = DCMView.horos_static_drawLock
        drawLock?.lock()

        let rArray = self.horos_curRoiList

        if let exception = HorosObjCException.caught({
            guard let rArray else { return }
            var i = 0
            while i < rArray.count {
                if let r = rArray.object(at: i) as? ROI, r.roImode == Int(ROI_selected) && !r.locked {
                    let groupID = r.groupID
                    // the notification can release it: a mirrored 2D point's owner removes it
                    ROIEventEmitter.willRemove(r)
                    self.removeROI(fromSliceOrVolume: r)
                    i -= 1
                    removed = true
                    if groupID != 0.0 {
                        self.deleteROIGroupID(groupID)
                    }
                }
                i += 1
            }

            ROIEventEmitter.removedFromList()

            if removed {
                self.selectSuccessorOfDeletedROIs()
            }
        }) {
            logROIEditingException(exception, "-[DCMView cut:]")
        }

        drawLock?.unlock()

        self.needsDisplay = true
    }

    // MARK: - Removal

    /// After the Delete key or Cut removed whole ROIs, select the slice's front
    /// ROI, the newest unless reordered, unless a ROI is still selected or being
    /// edited: the next Delete then removes it, without a click between them.
    @objc(selectSuccessorOfDeletedROIs)
    public dynamic func selectSuccessorOfDeletedROIs() {
        let rois = ViewROIEditing.rois(self.horos_curRoiList)
        guard let index = ViewROIEditing.session(rois).successorAfterDeletion(enabled: ROIDeletionSuccessor.isEnabled) else { return }

        let next = rois[index]
        next.roImode = Int(ROI_selected)
        ROIEventEmitter.selected(next)
    }

    /// A physical Length is one object shared by slice lists. Removing only the
    /// visible alias would resurrect it on the next slice and at the next save.
    @objc(removeROIFromSliceOrVolume:)
    public dynamic func removeROI(fromSliceOrVolume roi: ROI!) {
        guard let roi else { return }
        if self.is2DViewer() && roi is HorosVolumeLengthROI {
            for case let slice as NSMutableArray in self.horos_dcmRoiList ?? [] {
                slice.removeObject(identicalTo: roi)
            }
        } else {
            self.horos_curRoiList?.removeObject(identicalTo: roi)
        }
    }

    @objc(deleteROIGroupID:)
    public dynamic func deleteROIGroupID(_ groupID: TimeInterval) {
        let drawLock = DCMView.horos_static_drawLock
        drawLock?.lock()

        let rArray = self.horos_curRoiList

        if let exception = HorosObjCException.caught({
            guard let rArray else { return }
            var i = 0
            while i < rArray.count {
                if let r = rArray.object(at: i) as? ROI, r.groupID == groupID {
                    // The notification can change the array and release the ROI (a
                    // mirrored 2D point's owner removes it): the ROI removed is the
                    // one notified, kept until then.
                    ROIEventEmitter.willRemove(r)
                    self.removeROI(fromSliceOrVolume: r)
                    i -= 1

                    ROIEventEmitter.removedFromList()
                }
                i += 1
            }
        }) {
            logROIEditingException(exception, "-[DCMView deleteROIGroupID:]")
        }

        drawLock?.unlock()
    }

    /// Removes exactly these ROIs of the current image, as the Delete key removes
    /// the selected ones: undoable, locked ROIs kept, the ROIs of their group
    /// removed with them. Other ROIs that share a name are left alone: new ROIs
    /// are all "Unnamed" by default, so a removal by name took every one of them
    /// on every slice.
    @objc(deleteROIs:)
    public dynamic func deleteROIs(_ rois: [Any]!) {
        let list = self.horos_curRoiList
        var removable: [ROI] = []
        for case let r as ROI in rois ?? [] {
            if (list?.indexOfObjectIdentical(to: r) ?? 0) != NSNotFound && !r.locked && !removable.contains(where: { $0 === r }) {
                removable.append(r)
            }
        }

        if removable.isEmpty {
            return
        }

        sendToWindowController("addToUndoQueue:", "roi")
        self.stopROIEditingForce(true)

        let drawLock = DCMView.horos_static_drawLock
        drawLock?.lock()

        if let exception = HorosObjCException.caught({
            for r in removable {
                // An earlier ROI's group can have taken it already.
                if (self.horos_curRoiList?.indexOfObjectIdentical(to: r) ?? 0) == NSNotFound {
                    continue
                }

                let groupID = r.groupID
                // the notification can release it: a mirrored 2D point's owner removes it
                ROIEventEmitter.willRemove(r)
                self.removeROI(fromSliceOrVolume: r)
                if groupID != 0.0 {
                    self.deleteROIGroupID(groupID)
                }
            }

            ROIEventEmitter.removedFromList()
            self.selectSuccessorOfDeletedROIs()
        }) {
            logROIEditingException(exception, "-[DCMView deleteROIs:]")
        }

        drawLock?.unlock()

        self.needsDisplay = true
    }

    @objc(deleteInvalidROIsForArray:)
    public dynamic func deleteInvalidROIs(forArray r: NSMutableArray!) {
        // OsirixRemoveROINotification or OsirixROIRemovedFromArrayNotification can change/delete the NSArray !
        guard let r else { return }
        if let exception = HorosObjCException.caught({
            var i = 0
            while i < r.count {
                if let roi = r.object(at: i) as? ROI,
                   let removal = ROIEditingSession.invalidRemoval(isValid: roi.valid(), isCurrentROI: self.horos_curROI === roi) {
                    if removal.releasesCurrentROI {
                        self.horos_curROI = nil
                        self.horos_drawingROI = false
                    }

                    ROIEventEmitter.willRemove(roi)
                    r.removeObject(at: i)
                    i -= 1

                    ROIEventEmitter.removedFromList()
                }
                i += 1
            }
        }) {
            logROIEditingException(exception, "-[DCMView deleteInvalidROIsForArray:]", stack: false)
        }
    }

    @objc(deleteInvalidROIs)
    public dynamic func deleteInvalidROIs() {
        if let lists = self.horos_dcmRoiList {
            for case let r as NSMutableArray in lists {
                self.deleteInvalidROIs(forArray: r)
            }
        } else {
            // For sub-classes, such as MPR, Curved-MPR, ... they don't have the dcmRoiList array
            self.deleteInvalidROIs(forArray: self.horos_curRoiList)
        }
    }

    // MARK: - Join

    /// The contour's points in millimetres in the plane of the current image, so
    /// that contours of neighbouring images can be compared with it.
    @objc(planePointsOfROI:onImage:)
    public dynamic func planePoints(of roi: ROI!, onImage image: Int) -> [Any]! {
        guard let pix = self.horos_dcmPixList?.object(at: image) as? DCMPix, let plane = self.curDCM else { return [] }
        var o = [Double](repeating: 0, count: 9)
        plane.orientationDouble(&o)

        var points: [Any] = []
        for case let p as MyPoint in roi?.points ?? [] {
            var d = [Double](repeating: 0, count: 3)
            pix.convertDoubleX(Double(p.x), pixY: Double(p.y), toDICOMCoords: &d)
            let point = ROIEditing.planePoint((d[0], d[1], d[2]), origin: (plane.originX, plane.originY, plane.originZ), orientation: o)
            points.append(NSValue(point: point))
        }
        return points
    }

    /// A contour finished over a ROI of another image takes that ROI's name:
    /// volume, renaming and propagation group a series' ROIs by name, so the
    /// lesion outlined slice by slice is one object. The images are compared
    /// nearest first, at any distance: the missing ROIs are generated between
    /// contours drawn several images apart, which must be one object too.
    /// Images whose plane is not parallel to this one are not compared.
    @objc(joinFinishedContourToAdjacentObject)
    public dynamic func joinFinishedContourToAdjacentObject() {
        guard let roi = self.horos_contourAwaitingJoin, roi.roImode != Int(ROI_drawing) else { return }

        self.horos_contourAwaitingJoin = nil

        if (self.horos_curRoiList?.indexOfObjectIdentical(to: roi) ?? 0) == NSNotFound || !ROIObjectJoin.isEnabled {
            return
        }

        var here = [Double](repeating: 0, count: 9)
        self.curDCM?.orientationDouble(&here)

        let pixList = self.horos_dcmPixList
        let roiList = self.horos_dcmRoiList
        let curImage = Int(self.horos_curImage)
        // One distance at a time: the nearest images with a ROI the contour
        // covers decide, and the ROIs further away are not measured.
        let contour = (self.planePoints(of: roi, onImage: curImage) as? [NSValue]) ?? []
        let neighbours = ROIEditingSession.joinedImages(around: curImage, imageCount: pixList?.count ?? 0, roiListCount: roiList?.count ?? 0)
        var next = 0
        while next < neighbours.count {
            let distance = neighbours[next].distance
            var candidates: [[NSValue]] = [], names: [String] = []
            while next < neighbours.count, neighbours[next].distance == distance {
                let image = neighbours[next].image
                next += 1

                var there = [Double](repeating: 0, count: 9)
                (pixList?.object(at: image) as? DCMPix)?.orientationDouble(&there)
                if !ROIEditingSession.planesAreParallel(here, there) {
                    continue
                }

                for other in ViewROIEditing.rois(roiList?.object(at: image)) {
                    if !other.isValidForVolume() || ROIObjectJoin.isUnnamed(other.name) {
                        continue
                    }

                    candidates.append((self.planePoints(of: other, onImage: image) as? [NSValue]) ?? [])
                    names.append(other.name ?? "")
                }
            }

            let index = ROIObjectJoin.candidate(for: contour, candidates: candidates,
                                                imageDistances: [Int](repeating: distance, count: candidates.count))
            if index < 0 {
                continue
            }
            if let name = ROIEditingSession.joinedName(candidate: index, names: names, current: roi.name) {
                roi.name = name
                ROIEventEmitter.changed(roi)
            }
            return
        }
    }
}
