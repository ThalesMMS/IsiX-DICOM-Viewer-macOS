/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import UniformTypeIdentifiers

/// ToolsMenuIconSize, a macro of ViewerController.h that Swift does not import.
private let ToolsMenuIconSize = NSMakeSize(28.0, 28.0)

/// The 2D viewer's point ROIs shown as 3D points, the ROI volumes, the fly
/// through and the image exports of the surface rendering window.
extension SRController {
    // MARK: 3D points

    /// A 3D point added in the view: its 2D point ROI on the slice it falls in.
    @objc(add2DPoint:::)
    func add2DPoint(_ x: Float, _ y: Float, _ z: Float) {
        guard let viewer2D = viewer2DStorage, let pixList = viewer2D.pixList(), pixList.count > 1,
              let firstDCMPix = pixList.object(at: 0) as? DCMPix else { return }
        // compute 2D Coordinates
        var dc = [Double(x), Double(y), Double(z)]
        var sc = [Double](repeating: 0, count: 3)
        srView?.convert3Dto2Dpoint(&dc, &sc)

        // find the slice where we want to introduce the point
        let sliceNumber = Int(sc[2] + 0.5)

        guard sliceNumber >= 0 && sliceNumber < pixList.count,
              let sliceROIs = viewer2D.roiList()?.object(at: sliceNumber) as? NSMutableArray else { return }
        // Create the new 2D Point ROI
        let new2DPointROI: ROI = ROI(type: .t2DPoint, Float(firstDCMPix.pixelSpacingX), Float(firstDCMPix.pixelSpacingY),
                                DCMPix.originCorrected(accordingToOrientation: firstDCMPix))
        new2DPointROI.rect = NSRect(x: CGFloat(sc[0]), y: CGFloat(sc[1]), width: 0, height: 0)
        viewer2D.imageView()?.roiSet(new2DPointROI)
        // add the 2D Point ROI to the ROI list
        sliceROIs.add(new2DPointROI)
        // add the ROI to our list
        record2DPoint(new2DPointROI, slice: sliceNumber, (x, y, z))
        // notify the change
        NotificationCenter.default.post(name: .OsirixROIChange, object: new2DPointROI, userInfo: nil)
    }

    /// A 3D point removed in the view: its 2D point ROI leaves the 2D viewer.
    @objc(remove2DPoint:::)
    func remove2DPoint(_ x: Float, _ y: Float, _ z: Float) {
        guard let viewer2D = viewer2DStorage else { return }
        guard let index = roi2DPointsArray.indices.first(where: {
            x2DPointsArray[$0] == x && y2DPointsArray[$0] == y && z2DPointsArray[$0] == z
        }) else { return }
        // the 2D Point ROI object
        let cur2DPoint = roi2DPointsArray[index]
        // remove 2D Point on 2D viewer2D
        (viewer2D.roiList()?.object(at: sliceNumber2DPointsArray[index]) as? NSMutableArray)?.remove(cur2DPoint)
        //notify
        NotificationCenter.default.post(name: .OsirixRemoveROI, object: cur2DPoint, userInfo: nil)
        NotificationCenter.default.post(name: .OsirixUpdateView, object: nil, userInfo: nil)
        // remove 2D point in our list
        // done by remove3DPoint (through notification)
    }

    /// The patient location of a 2D point ROI, on its own image or the one shown.
    private func location(of roi: ROI) -> (x: Float, y: Float, z: Float)? {
        guard let viewer2D = viewer2DStorage else { return nil }
        let curImage = viewer2D.imageView()?.curImage ?? 0
        guard let pix = roi.pix ?? viewer2D.pixList()?.object(at: curImage) as? DCMPix,
              let point = roi.points?.object(at: 0) as? MyPoint else { return nil }
        return Self.patientLocation(of: point, on: pix)
    }

    /// Shows a 2D point ROI as a 3D point.
    private func show2DPoint(_ roi: ROI) {
        guard let location = location(of: roi) else { return }
        // add the 3D Point to the view
        srView?.add3DPoint(Double(location.x), Double(location.y), Double(location.z))
        srView?.needsDisplay = true
        // add the 2D Point to our list
        record2DPoint(roi, slice: viewer2DStorage?.imageView()?.curImage ?? 0, location)
    }

    @objc func refresh3DPoints() {
        let roiList = (viewer2DStorage?.roiList() as? [NSArray]) ?? []
        // First remove all non-available points
        let roisToBeRemoved = roi2DPointsArray.filter { r in !roiList.contains { $0.contains(r) } }
        for r in roisToBeRemoved { remove3DPointROI(r) }

        // Add all non-displayed points
        for a in roiList {
            for case let r as ROI in a where r.type == .t2DPoint && !roi2DPointsArray.contains(r) {
                show2DPoint(r)
            }
        }
    }

    /// A ROI selected in the 2D viewer: a point ROI shows as a 3D point.
    @objc(add3DPoint:)
    func add3DPoint(_ note: Notification?) {
        refresh3DPoints()

        // Add the new ROI
        guard let addedROI = note?.object as? ROI else { return }
        if roi2DPointsArray.contains(addedROI) {
            remove3DPoint(note)
        }
        if addedROI.type == .t2DPoint {
            show2DPoint(addedROI)
        }
    }

    @objc(remove3DPointROI:)
    func remove3DPointROI(_ removedROI: ROI?) {
        guard let index = roi2DPointsArray.firstIndex(where: { $0 === removedROI }) else { return }
        // remove the 3D Point in the SR view
        srView?.remove3DPoint(at: UInt32(index))
        srView?.needsDisplay = true
        // remove 2D point in our list
        roi2DPointsArray.remove(at: index)
        sliceNumber2DPointsArray.remove(at: index)
        x2DPointsArray.remove(at: index)
        y2DPointsArray.remove(at: index)
        z2DPointsArray.remove(at: index)
    }

    @objc(remove3DPoint:)
    func remove3DPoint(_ note: Notification?) {
        if let removedROI = note?.object as? ROI, removedROI.type == .t2DPoint { // 2D Points
            remove3DPointROI(removedROI)
        }
    }

    // MARK: ROI volumes

    /// A volume for each name of the 2D viewer's ROIs that makes one.
    @objc func computeROIVolumes() {
        roiVolumesStorage.removeAllObjects()
        for case let name as String in viewer2DStorage?.roiNames() ?? NSArray() {
            let roisWithCurrentName = viewer2DStorage?.rois(withName: name) as? [ROI]
            let volume = ROIVolume(viewer: viewer2DStorage)
            volume.setROIList(roisWithCurrentName)
            if volume.isVolume() {
                roiVolumesStorage.add(volume)
            }
        }
    }

    override nonisolated func roiVolumes() -> [Any]! {
        roiVolumesStorage as? [Any]
    }

    override func displayROIVolume(_ v: Any!) {
        if let actor = (v as? ROIVolume)?.surfaceActor { srView?.scene.addActor(actor) }
    }

    override func hideROIVolume(_ v: Any!) {
        if let actor = (v as? ROIVolume)?.surfaceActor { srView?.scene.removeActor(actor) }
    }

    @objc func displayROIVolumes() {
        for case let volume as ROIVolume in roiVolumesStorage where volume.visible() {
            displayROIVolume(volume)
        }
    }

    @IBAction func roiGetManager(_ sender: Any?) {
        let found = NSApp.windows.contains { ($0.windowController?.windowNibName as String?) == "ROIVolumeManager" }
        if found {
            NSLog("FOUND!!")
            return
        }
        let manager = ROIVolumeManagerController(viewer: self)
        manager.showWindow(self)
        manager.window?.makeKeyAndOrderFront(self)
        // The manager keeps itself until its window closes, as before.
        _ = Unmanaged.passRetained(manager)
    }

    // MARK: Fly Thru

    @objc func flyThruController() -> FlyThruController? {
        for w in NSApp.windows {
            if let controller = w.windowController as? FlyThruController, controller.windowNibName == "FlyThru",
               controller.window3DController() === self {
                return controller
            }
        }
        return nil
    }

    @IBAction func flyThruButtonMenu(_ sender: Any?) {
        flyThruControllerInit(self)
        flyThruController()?.stepsArrayController?.flyThruTag(Int32(truncatingIfNeeded: (sender as AnyObject?)?.tag ?? 0))
    }

    @IBAction func flyThruControllerInit(_ sender: Any?) {
        //Only open 1 fly through controller
        if flyThruController() != nil { return }

        let adapter = SRFlyThruAdapter(srController: self)
        let flyThruController = FlyThruController(flyThruAdapter: adapter)
        flyThruController.loadWindow()
        flyThruController.window?.makeKeyAndOrderFront(sender)
        flyThruController.setWindow3DController(self)
        // The fly-through window keeps its controller until it closes, as before.
        _ = Unmanaged.passRetained(flyThruController)
    }

    @objc func recordFlyThru() {
        let now = Date.timeIntervalSinceReferenceDate
        if now - flyThruRecordingTimeFrame < 1.0 { return }

        flyThruRecordingTimeFrame = now
        flyThruControllerInit(self)
        flyThruController()?.stepsArrayController?.flyThruTag(0)
    }

    // MARK: Image exports

    /// The view's image as JPEG, at 90 %.
    private func jpegData() -> Data? {
        guard let image = srView?.nsimage(false) else { return nil }
        return NSBitmapImageRep.representationOfImageReps(in: image.representations, using: .jpeg,
                                                          properties: [.compressionFactor: NSDecimalNumber(value: Float(0.9))])
    }

    @IBAction func export2iPhoto(_ sender: Any?) {
        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString)
            .appendingPathComponent("IsiX DICOM Viewer.jpg")
        (jpegData() as NSData?)?.write(toFile: path, atomically: true)

        _ = Photos().importInPhotos([path])
    }

    @IBAction func exportJPEG(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        panel.nameFieldStringValue = NSLocalizedString("3D SR Image", comment: "")
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            (self.jpegData() as NSData?)?.write(toFile: url.path, atomically: true)
            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @IBAction func exportTIFF(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "tif")!]
        panel.nameFieldStringValue = NSLocalizedString("3D SR Image", comment: "")
        if !["tif", "tiff"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".tif"
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            (self.srView?.nsimage(false).tiffRepresentation as NSData?)?.write(toFile: url.path, atomically: false)
            if UserDefaults.standard.bool(forKey: "OPENVIEWER") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
