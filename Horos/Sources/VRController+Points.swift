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


import Cocoa

/// The 3D points of the VR window, which are the 2D viewer's point ROIs (a
/// point added in 3D becomes a ROI of its slice, a ROI added or removed in 2D
/// a point of the view), and the ROI volumes it shows, one list per time.
extension VRController {

    // MARK: - 3D points

    @objc(add2DPoint::::)
    public final func add2DPoint(_ x: Float, _ y: Float, _ z: Float, _ mm: UnsafeMutablePointer<Float>!) {
        // The default colour: a ROI keeps its own when given (0, 1, 2).
        add2DPoint(x, y, z, mm, RGBColor(red: 0, green: 1, blue: 2))
    }

    /// A point ROI on the slice nearest to `z`, at (x, y), whose position in
    /// millimetres is `mm`; `rgb` its colour unless it is (0, 1, 2).
    @objc(add2DPoint:::::)
    public final func add2DPoint(_ x: Float, _ y: Float, _ z: Float, _ mm: UnsafeMutablePointer<Float>!, _ rgb: RGBColor) {
        guard let viewer2D = viewer2DStorage, let firstDCMPix = viewer2D.pixList()?.object(at: 0) as? DCMPix else { return }
        // find the slice where we want to add the point
        let sliceNumber = Int(Double(z) + 0.5)
        guard sliceNumber >= 0 && sliceNumber < (viewer2D.pixList()?.count ?? 0) else { return }
        // Create the new 2D Point ROI
        guard let new2DPointROI = ROI(type: .t2DPoint, Float(firstDCMPix.pixelSpacingX), Float(firstDCMPix.pixelSpacingY),
                                      DCMPix.originCorrected(accordingToOrientation: firstDCMPix)) else { return }
        if rgb.red != 0 && rgb.green != 1 && rgb.blue != 2 {
            new2DPointROI.rgbcolor = rgb
        }
        new2DPointROI.rect = NSRect(x: CGFloat(x), y: CGFloat(y), width: 0, height: 0)
        viewer2D.imageView()?.roiSet(new2DPointROI)
        // add the 2D Point ROI to the ROI list
        (viewer2D.roiList()?[sliceNumber] as? NSMutableArray)?.add(new2DPointROI)
        // add the ROI to our list
        roi2DPointsArray?.add(new2DPointROI)
        sliceNumber2DPointsArray?.add(NSNumber(value: sliceNumber))
        x2DPointsArray?.add(NSNumber(value: mm?[0] ?? 0))
        y2DPointsArray?.add(NSNumber(value: mm?[1] ?? 0))
        z2DPointsArray?.add(NSNumber(value: mm?[2] ?? 0))
        // notify the change
        NotificationCenter.default.post(name: .OsirixROIChange, object: new2DPointROI, userInfo: nil)
    }

    /// The point ROI within a pixel (and a slice interval) of the position in
    /// millimetres (x, y, z), scaled by the view's factor, removed from its
    /// slice; the view's point goes when the removal is notified back.
    @objc(remove2DPoint:::)
    public final func remove2DPoint(_ x: Float, _ y: Float, _ z: Float) {
        guard let viewer2D = viewer2DStorage, let firstDCMPix = viewer2D.pixList()?.object(at: 0) as? DCMPix,
              let points = roi2DPointsArray else { return }
        let factor = factor()
        let x = x / factor, y = y / factor, z = z / factor
        NSLog("%f %f %f", x, y, z)
        var found: Int?
        for index in 0..<points.count {
            let sx = (x2DPointsArray?.object(at: index) as? NSNumber)?.floatValue ?? 0
            let sy = (y2DPointsArray?.object(at: index) as? NSNumber)?.floatValue ?? 0
            let sz = (z2DPointsArray?.object(at: index) as? NSNumber)?.floatValue ?? 0
            NSLog("%f %f %f", sx, sy, sz)
            // float against double, compared in double as before.
            let (dx, dy, dz) = (Double(x), Double(y), Double(z))
            if dx < Double(sx) + firstDCMPix.pixelSpacingX && dx > Double(sx) - firstDCMPix.pixelSpacingX
                && dy < Double(sy) + firstDCMPix.pixelSpacingY && dy > Double(sy) - firstDCMPix.pixelSpacingY
                && dz < Double(sz) + firstDCMPix.sliceInterval && dz > Double(sz) - firstDCMPix.sliceInterval {
                found = index
                break
            }
        }
        guard let index = found, let point = points.object(at: index) as? ROI else { return }
        // remove 2D Point on 2D viewer2D
        let slice = (sliceNumber2DPointsArray?.object(at: index) as? NSNumber)?.intValue ?? 0
        (viewer2D.roiList()?[slice] as? NSMutableArray)?.remove(point)
        // notify; our lists lose it through -remove3DPoint:
        NotificationCenter.default.post(name: .OsirixRemoveROI, object: point, userInfo: nil)
        NotificationCenter.default.post(name: .OsirixUpdateView, object: nil, userInfo: nil)
    }

    /// The position in millimetres of a point ROI, on its image or, without
    /// one, the 2D viewer's current image.
    private func dicomPosition(of roi: ROI, in viewer2D: ViewerController) -> [Float] {
        var location = [Float](repeating: 0, count: 3)
        let pix = roi.pix ?? viewer2D.pixList()?.object(at: Int(viewer2D.imageView()?.curImage ?? 0)) as? DCMPix
        let point = roi.points?.object(at: 0) as? MyPoint
        pix?.convertX(point?.x ?? 0, pixY: point?.y ?? 0, toDICOMCoords: &location, pixelCenter: true)
        return location
    }

    /// The view's point of a ROI and its place in the lists, at the 2D
    /// viewer's current image.
    private func addPoint(of roi: ROI, in viewer2D: ViewerController) {
        let location = dicomPosition(of: roi, in: viewer2D)
        let x = Double(location[0]), y = Double(location[1]), z = Double(location[2])
        // add the 3D Point to the view
        vrView?.add3DPoint(x, y, z, roi.thickness, Float(Double(roi.rgbcolor.red) / 65535.0),
                           Float(Double(roi.rgbcolor.green) / 65535.0), Float(Double(roi.rgbcolor.blue) / 65535.0))
        vrView?.needsDisplay = true
        // add the 2D Point to our list
        roi2DPointsArray?.add(roi)
        sliceNumber2DPointsArray?.add(NSNumber(value: Int(viewer2D.imageView()?.curImage ?? 0)))
        x2DPointsArray?.add(NSNumber(value: Float(x)))
        y2DPointsArray?.add(NSNumber(value: Float(y)))
        z2DPointsArray?.add(NSNumber(value: Float(z)))
    }

    /// The view's points brought in line with the 2D viewer's point ROIs: the
    /// ones whose ROI is gone are removed, the ROIs not shown are added.
    @objc(refresh3DPoints)
    public final func refresh3DPoints() {
        guard let viewer2D = viewer2DStorage else {
            for case let roi as ROI in (roi2DPointsArray?.copy() as? NSArray) ?? NSArray() { remove3DPointROI(roi) }
            return
        }
        let roiLists = (viewer2D.roiList() as NSArray?) ?? NSArray()
        var roisToBeRemoved: [ROI] = []
        for case let r as ROI in roi2DPointsArray ?? NSMutableArray() {
            let found = roiLists.contains { ($0 as? NSArray)?.contains(r) ?? false }
            if !found { roisToBeRemoved.append(r) }
        }
        for r in roisToBeRemoved { remove3DPointROI(r) }

        // Add all non-displayed points
        for case let list as NSArray in roiLists {
            for case let r as ROI in list where r.type == .t2DPoint {
                if roi2DPointsArray?.contains(r) == false {
                    addPoint(of: r, in: viewer2D)
                }
            }
        }
    }

    /// A ROI selected in 2D: the points are refreshed and, for a point ROI,
    /// its point added again.
    @objc(add3DPoint:)
    public final func add3DPoint(_ note: Notification!) {
        refresh3DPoints()
        guard let addedROI = note?.object as? ROI else { return }
        if roi2DPointsArray?.contains(addedROI) == true { remove3DPoint(note) }
        if addedROI.type == .t2DPoint, let viewer2D = viewer2DStorage {
            addPoint(of: addedROI, in: viewer2D)
        }
    }

    @objc(remove3DPointROI:)
    public final func remove3DPointROI(_ removedROI: ROI!) {
        guard let points = roi2DPointsArray else { return }
        let index = points.indexOfObjectIdentical(to: removedROI as Any)
        guard index != NSNotFound else { return }
        // remove the 3D Point in the SR view
        vrView?.remove3DPoint(at: UInt32(index))
        vrView?.needsDisplay = true
        // remove 2D point in our list
        points.removeObject(at: index)
        sliceNumber2DPointsArray?.removeObject(at: index)
        x2DPointsArray?.removeObject(at: index)
        y2DPointsArray?.removeObject(at: index)
        z2DPointsArray?.removeObject(at: index)
    }

    @objc(remove3DPoint:)
    public final func remove3DPoint(_ note: Notification!) {
        guard let removedROI = note?.object as? ROI, removedROI.type == .t2DPoint else { return }
        remove3DPointROI(removedROI)
    }

    @objc(roi2DPointsArray)
    public final func roi2DPointsArrayValue() -> NSMutableArray? { roi2DPointsArray }

    @objc(sliceNumber2DPointsArray)
    public final func sliceNumber2DPointsArrayValue() -> NSMutableArray? { sliceNumber2DPointsArray }

    // MARK: - ROI volumes

    /// For every time, the volumes of the 2D viewer's ROIs of each name.
    @objc(computeROIVolumes)
    public final func computeROIVolumes() {
        guard let viewer2D = viewer2DStorage else {
            for m in 0..<Int(maxMovieIndex) { roiVolumeLists[m]?.removeAllObjects() }
            return
        }
        let roiNames = viewer2D.roiNames() ?? []
        for m in 0..<Int(maxMovieIndex) {
            roiVolumeLists[m]?.removeAllObjects()
            for name in roiNames {
                let roisWithCurrentName = viewer2D.rois(withName: name as? String, forMovieIndex: Int32(m))
                guard let volume = roiVolumeClass()?.init(viewer: viewer2D) else { continue }
                volume.setFactor(factor())
                volume.setROIList(roisWithCurrentName as? [Any])
                if volume.isVolume() {
                    roiVolumeLists[m]?.add(volume)
                }
            }
        }
    }

    public nonisolated override func roiVolumes() -> [Any]! {
        roiVolumeLists[Int(curMovieIndexStorage)].map { $0 as [AnyObject] }
    }

    /// The current time's volumes, the list itself.
    @objc(horosROIVolumeList)
    public nonisolated final func horosROIVolumeList() -> NSMutableArray? {
        roiVolumeLists[Int(curMovieIndexStorage)]
    }

    public override func displayROIVolume(_ v: Any!) {
        guard let volume = roiVolume(v), let actor = volume.roiVolumeActor()?.pointerValue,
              let renderer = vrView?.vtkRenderer() else { return }
        do {
            try IsiXVTKRendererProps.addProp(actor, toRenderer: renderer)
        } catch {
            NSLog("VRController: %@", error.localizedDescription)
        }
    }

    public override func hideROIVolume(_ v: Any!) {
        guard let volume = roiVolume(v), volume.isRoiVolumeActorComputed(), let actor = volume.roiVolumeActor()?.pointerValue,
              let renderer = vrView?.vtkRenderer() else { return }
        do {
            try IsiXVTKRendererProps.removeProp(actor, fromRenderer: renderer)
        } catch {
            NSLog("VRController: %@", error.localizedDescription)
        }
    }

    /// Every time's volumes hidden, and the visible ones of the current time shown.
    @objc(displayROIVolumes)
    public final func displayROIVolumes() {
        for m in 0..<Int(maxMovieIndex) {
            for volume in (roiVolumeLists[m] as? [Any]) ?? [] { hideROIVolume(volume) }
        }
        for item in roiVolumeLists[Int(curMovieIndexStorage)] ?? NSMutableArray() {
            if let volume = roiVolume(item), volume.visible() { displayROIVolume(volume) }
        }
    }

    @IBAction @objc(roiGetManager:)
    public final func roiGetManager(_ sender: Any!) {
        let found = NSApp.windows.contains { $0.windowController?.windowNibName == "ROIVolumeManager" }
        if !found {
            let manager = ROIVolumeManagerController(viewer: self)
            // [[ROIVolumeManagerController alloc] init...]: never released here, as before.
            _ = Unmanaged.passRetained(manager)
            manager.showWindow(self)
            manager.window?.makeKeyAndOrderFront(self)
        }
    }

    /// A display property of a ROI volume changed: the volumes of the same
    /// name at the other times follow.
    @objc(updateROIVolume:)
    public final func updateROIVolume(_ notification: Notification!) {
        guard let changed = roiVolume(notification?.object) else { return }
        let key = notification?.userInfo?["key"]
        for m in 0..<Int(maxMovieIndex) {
            guard let list = roiVolumeLists[m] else { continue }
            let index = list.indexOfObjectIdentical(to: changed)
            guard index != NSNotFound else { continue }
            for n in 0..<Int(maxMovieIndex) {
                guard let other = roiVolume(roiVolumeLists[n]?.object(at: index)) else { continue }
                let mine = (other.displayProperties() as NSDictionary?)?.object(forKey: key as Any)
                let theirs = (changed.displayProperties() as NSDictionary?)?.object(forKey: key as Any)
                // -isEqualTo: sent to nil answered NO: a missing property is copied too.
                if !((mine as AnyObject?)?.isEqual(to: theirs) ?? false) {
                    other.setDisplayProperties(changed.displayProperties())
                }
            }
        }
    }
}

/// What the 3D window sends to its ROI volumes. ROIVolume's header declares
/// VTK types, which Swift cannot import, so the messages are named here; the
/// class does not adopt the protocol, and the messages reach it as the
/// Objective-C ones did.
@objc private protocol ROIVolumeMessages: NSObjectProtocol {
    @objc(initWithViewer:) init(viewer: ViewerController?)
    @objc(setFactor:) func setFactor(_ factor: Float)
    @objc(setROIList:) func setROIList(_ list: [Any]?)
    @objc(isVolume) func isVolume() -> Bool
    @objc(visible) func visible() -> Bool
    @objc(isRoiVolumeActorComputed) func isRoiVolumeActorComputed() -> Bool
    @objc(roiVolumeActor) func roiVolumeActor() -> NSValue?
    @objc(displayProperties) func displayProperties() -> NSMutableDictionary?
    @objc(setDisplayProperties:) func setDisplayProperties(_ properties: NSDictionary?)
}

/// The ROIVolume class, to create volumes with -initWithViewer:.
private func roiVolumeClass() -> ROIVolumeMessages.Type? {
    guard let cls = NSClassFromString("ROIVolume") else { return nil }
    return unsafeBitCast(cls, to: ROIVolumeMessages.Type.self)
}

/// `item` as a ROI volume: an instance of ROIVolume, or nil.
private func roiVolume(_ item: Any?) -> ROIVolumeMessages? {
    guard let object = item as? NSObject, let cls = NSClassFromString("ROIVolume"), object.isKind(of: cls) else { return nil }
    return unsafeBitCast(object, to: ROIVolumeMessages.self)
}
