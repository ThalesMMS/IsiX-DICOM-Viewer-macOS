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
import UniformTypeIdentifiers

/// What leaves the VR window: the picture by mail, to Photos, in a JPEG,
/// TIFF or DICOM file, and the camera path of the fly-thru window.
extension VRController {

    @objc(sendMail:)
    public final func sendMail(_ sender: Any!) {
        sendMailImage(vrView?.nsimage(false))
    }

    /// The picture's JPEG at 0.9, as the export panels write it.
    private func jpegData(_ image: NSImage?) -> Data? {
        NSBitmapImageRep.representationOfImageReps(in: image?.representations ?? [], using: .jpeg,
                                                    properties: [.compressionFactor: NSDecimalNumber(value: 0.9)])
    }

    @objc(exportJPEG:)
    public final func exportJPEG(_ sender: Any!) {
        let panel = NSSavePanel()
        let image = vrView?.nsimage(false)
        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "jpg")!]
        panel.nameFieldStringValue = NSLocalizedString("3D VR Image", comment: "")
        if !["jpg", "jpeg"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".jpg"
        }
        panel.begin { [self] result in
            guard result == .OK, let url = panel.url else { return }
            try? jpegData(image)?.write(to: url, options: .atomic)
            if UserDefaults.standard.bool(forKey: "OPENVIEWER") { NSWorkspace.shared.open(url) }
        }
    }

    @objc(export2iPhoto:)
    public final func export2iPhoto(_ sender: Any!) {
        let image = vrView?.nsimage(false)
        let path = ((BrowserController.currentBrowser()?.database?.tempDirPath() ?? "") as NSString)
            .appendingPathComponent("IsiX DICOM Viewer.jpg")
        try? jpegData(image)?.write(to: URL(fileURLWithPath: path), options: .atomic)
        Photos().importInPhotos([path])
    }

    @objc(exportTIFF:)
    public final func exportTIFF(_ sender: Any!) {
        let panel = NSSavePanel()
        let image = vrView?.nsimage(false)
        panel.canSelectHiddenExtension = true
        panel.allowedContentTypes = [UTType(filenameExtension: "tif")!]
        panel.nameFieldStringValue = NSLocalizedString("3D VR Image", comment: "")
        if !["tif", "tiff"].contains((panel.nameFieldStringValue as NSString).pathExtension.lowercased()) {
            panel.nameFieldStringValue += ".tif"
        }
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            try? image?.tiffRepresentation?.write(to: url)
            if UserDefaults.standard.bool(forKey: "OPENVIEWER") { NSWorkspace.shared.open(url) }
        }
    }

    @objc(exportDICOMFile:)
    public final func exportDICOMFile(_ sender: Any!) {
        vrView?.exportDICOM()
    }

    // MARK: - Fly Thru

    @IBAction @objc(flyThruButtonMenu:)
    public final func flyThruButtonMenu(_ sender: Any!) {
        flyThruControllerInit(self)
        flyThruController()?.stepsArrayController?.flyThruTag(Int32(truncatingIfNeeded: (sender as AnyObject?)?.tag ?? 0))
    }

    /// The fly-thru window of this controller, opened once: the window
    /// retains its adapter, which the controller keeps without a retain.
    @IBAction @objc(flyThruControllerInit:)
    public func flyThruControllerInit(_ sender: Any!) {
        // Only open 1 fly through controller
        if flyThruController() != nil { return }
        let adapter = VRFlyThruAdapter(vrController: self)
        FTAdapter = adapter
        let flyThruController = FlyThruController(flyThruAdapter: adapter)
        // [[FlyThruController alloc] init...]: never released here, as before.
        _ = Unmanaged.passRetained(flyThruController)
        flyThruController.loadWindow()
        flyThruController.window?.makeKeyAndOrderFront(sender)
        flyThruController.setWindow3DController(self)
    }

    @objc(flyThruController)
    public final func flyThruController() -> FlyThruController? {
        for window in NSApp.windows {
            guard let controller = window.windowController as? FlyThruController, controller.windowNibName == "FlyThru",
                  controller.window3DController() === self else { continue }
            return controller
        }
        return nil
    }

    /// A step of the fly-thru path at the current camera, once a second at most.
    @objc(recordFlyThru)
    public final func recordFlyThru() {
        let now = Date.timeIntervalSinceReferenceDate
        if now - flyThruRecordingTimeFrame < 1.0 { return }
        flyThruRecordingTimeFrame = now
        flyThruControllerInit(self)
        flyThruController()?.stepsArrayController?.flyThruTag(0)
    }
}
