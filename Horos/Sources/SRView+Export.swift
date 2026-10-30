/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:  OsiriX
 Copyright (c) OsiriX Team
 All rights reserved.
 Distributed under GNU - LGPL
 
 See http://www.osirix-viewer.com/copyright.html for details.
   This software is distributed WITHOUT ANY WARRANTY; without even
   the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
   PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa
import UniformTypeIdentifiers

/// The pasteboard type under which the modifier flags of a drag are looked
/// for when the promised file is written.
private let SRPasteboardTypeEventModifierFlags = "com.opensource.osirix.eventmodifierflags"

/// The surface view's pictures and exports: its frame with the overlay, a
/// QuickTime turn, DICOM images and series, the scene in a 3D file format,
/// the pasteboard and the drags.
extension SRView: NSDraggingSource, NSPasteboardItemDataProvider {
    @objc(print:)
    override func printView(_ sender: Any?) {
        // The window controller prints the view (Window3DController.print).
        _ = controller?.perform(NSSelectorFromString("print:"), with: sender)
    }

    // MARK: QuickTime

    /// A frame of the turn: the camera turned by a frame's share of the angle.
    @objc(imageForFrame:maxFrame:)
    func imageForFrame(_ cur: NSNumber, maxFrame max: NSNumber) -> NSImage {
        if cur.intValue != -1 {
            switch rotationOrientation {
            case 0: azimuth(rotation() / max.floatValue)
            case 1: vertical(rotation() / max.floatValue)
            default: break
            }
        }
        return nsimageQuicktime()
    }

    /// A frame of a QuickTime VR turn.
    @objc(imageForFrameVR:maxFrame:)
    func imageForFrameVR(_ cur: NSNumber, maxFrame max: NSNumber) -> NSImage {
        let camera = scene.camera
        if cur.intValue == -1 {
            camPosition = camera.position
            camFocal = camera.viewUp
            return nsimageQuicktime()
        }
        let step = Double(360 / numberOfFramesValue)
        if max.intValue > 36 {
            if cur.intValue % numberOfFramesValue == 0 && cur.intValue != 0 {
                camera.azimuth(step)
                vertical(-Float(360 / numberOfFramesValue))
            } else if cur.intValue != 0 {
                camera.azimuth(step)
            }
        } else if cur.intValue != 0 {
            camera.azimuth(step)
        }
        camera.orthogonalizeViewUp()
        camera.computeViewPlaneNormal()
        return nsimageQuicktime()
    }

    @IBAction @objc(endQuicktimeSettings:)
    func endQuicktimeSettings(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? 0
        export3DWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))
        numberOfFramesValue = Int(framesSlider?.intValue ?? 0)
        rotationValue = rotationMatrix?.selectedCell()?.tag == 1 ? 360 : 180
        guard tag != 0 else { return }

        setViewSizeToMatrix3DExport()
        let name = ((window?.windowController as? Window3DController)?.fileList()?.first as AnyObject?)?.value(forKeyPath: "series.study.name") as? String
        let movie = QuicktimeExport(selector: self, #selector(imageForFrame(_:maxFrame:)), numberOfFramesValue)
        movie?.createMovieQTKit(true, false, name)
        restoreViewSizeAfterMatrix3DExport()
    }

    @objc func rotation() -> Float { rotationValue }
    @objc func numberOfFrames() -> Float { Float(numberOfFramesValue) }

    @IBAction @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any?) {
        if let export3DWindow { window?.beginSheet(export3DWindow, completionHandler: nil) }
    }

    /// The frame for a movie: the outline box taken out while it is captured.
    @objc func nsimageQuicktime() -> NSImage {
        var wasPresent = false
        if let outline, scene.contains(outline) {
            scene.removeActor(outline)
            wasPresent = true
        }
        display()
        let image = nsimage(true)
        if wasPresent, let outline { scene.addActor(outline) }
        return image
    }

    // MARK: 3D file formats

    /// The scene in a 3D file: RenderMan (1), VRML (2), Inventor (3), OBJ (4),
    /// or the surfaces in STL (5), without the orientation cube.
    @IBAction @objc(export3DFileFormat:)
    func export3DFileFormat(_ sender: Any?) {
        let tag = (sender as AnyObject?)?.tag ?? 0
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = true
        switch tag {
        case 1: panel.allowedContentTypes = [UTType(filenameExtension: "rib")!]
        case 2: panel.allowedContentTypes = [UTType(filenameExtension: "wrl")!]
        case 3: panel.allowedContentTypes = [UTType(filenameExtension: "iv")!]
        case 4: panel.allowedContentTypes = [UTType(filenameExtension: "obj")!]
        case 5: panel.allowedContentTypes = [UTType(filenameExtension: "stl")!]
        default: break
        }
        panel.nameFieldStringValue = "3DFile"

        panel.begin { [weak self] result in
            guard let self, result == .OK, let path = panel.url?.path else { return }
            var orientationSwitch = false
            if self.horosOrientationCubeShown {
                orientationSwitch = true
                self.switchOrientationWidget(self)
            }
            let splashExport = WaitRendering(NSLocalizedString("Exporting...", comment: ""))
            splashExport?.showWindow(self)

            do {
                switch tag {
                case 1: try self.scene.export(.RIB, to: path)
                case 2: try self.scene.export(.VRML, to: path)
                case 3: try self.scene.export(.inventor, to: path)
                case 4: try self.scene.export(.OBJ, to: path)
                case 5: try IsiXVTKScene.writeSTL(of: self.surfaces, to: path)
                default: break
                }
            } catch {
                NSLog("---- SRView: the 3D export failed: %@", String(describing: error))
            }

            splashExport?.close()
            if orientationSwitch { self.switchOrientationWidget(self) }
        }
    }

    // MARK: DICOM

    /// Enables the series settings of the DICOM sheet for a series (tag 1).
    @IBAction @objc(setCurrentdcmExport:)
    func setCurrentdcmExport(_ sender: Any?) {
        guard let dcmBox else { return }
        SRView.enable(dcmBox, (sender as? NSMatrix)?.selectedCell()?.tag == 1)
    }

    private static func enable(_ view: NSView, _ on: Bool) {
        if let control = view as? NSControl {
            control.isEnabled = on
            return
        }
        for subview in view.subviews { enable(subview, on) }
    }

    @IBAction @objc(endDCMExportSettings:)
    func endDCMExportSettings(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? 0
        exportDCMWindow?.makeFirstResponder(nil)
        exportDCMWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        numberOfFramesValue = Int(dcmframesSlider?.intValue ?? 0)
        rotationValue = dcmrotation?.selectedCell()?.tag == 1 ? 360 : 180
        rotationOrientation = dcmorientation?.selectedCell()?.tag == 1 ? 1 : 0
        guard tag != 0 else { return }

        var produced: [String] = []
        setViewSizeToMatrix3DExport()

        if dcmExportMode?.selectedCell()?.tag == 0 {
            // CURRENT image only.
            if exportDCM == nil { exportDCM = DICOMExport() }
            var width = 0, height = 0, spp = 0, bpp = 0
            if let data = getRawPixels(&width, &height, &spp, &bpp, true, true), let exportDCM {
                exportDCM.setSourceFile(firstObject?.srcFile)
                exportDCM.setSeriesDescription(dcmSeriesName?.stringValue)
                // A new series at each export: the exporter is kept, and with
                // the same number the image went into the previous export's series.
                exportDCM.beginSeries(withNumber: 5500)
                exportDCM.setPixelData(data, samplesPerPixel: Int32(spp), bitsPerSample: Int32(bpp), width: width, height: height)
                var o = [Float](repeating: 0, count: 9)
                getOrientation(&o)
                if UserDefaults.standard.bool(forKey: "exportOrientationIn3DExport") { exportDCM.setOrientation(&o) }
                if let file = exportDCM.writeDCMFile(nil) {
                    produced.append(file)
                } else {
                    HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                                message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                }
                free(data)
            }
        } else {
            // A 3D sequence.
            let sequence = DICOMExport()
            let progress = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
            progress?.showWindow(self)
            progress?.progress()?.maxValue = Double(numberOfFramesValue)

            let now = Calendar.current.dateComponents([.minute, .second], from: Date())
            sequence.setSeriesNumber(5500 + (now.minute ?? 0) + (now.second ?? 0))
            sequence.setSeriesDescription(dcmSeriesName?.stringValue)
            sequence.setSourceFile(firstObject?.srcFile)

            var wasPresent = false
            if let outline, scene.contains(outline) {
                scene.removeActor(outline)
                wasPresent = true
            }
            if let textX { scene.removeText(textX) }
            display()
            for _ in 0..<numberOfFramesValue {
                autoreleasepool {
                    var width = 0, height = 0, spp = 0, bpp = 0
                    if let data = getRawPixels(&width, &height, &spp, &bpp, true, true) {
                        var o = [Float](repeating: 0, count: 9)
                        getOrientation(&o)
                        if UserDefaults.standard.bool(forKey: "exportOrientationIn3DExport") { sequence.setOrientation(&o) }
                        sequence.setPixelData(data, samplesPerPixel: Int32(spp), bitsPerSample: Int32(bpp), width: width, height: height)
                        if let file = sequence.writeDCMFile(nil) { produced.append(file) }
                        free(data)
                    }
                    switch rotationOrientation {
                    case 0: azimuth(rotationValue / Float(numberOfFramesValue))
                    case 1: vertical(rotationValue / Float(numberOfFramesValue))
                    default: break
                    }
                    display()
                    progress?.increment(by: 1)
                }
            }
            if wasPresent, let outline { scene.addActor(outline) }
            if let textX { scene.addText(textX) }
            progress?.close()
        }

        HorosSceneView.importExportedFiles(produced)
        restoreViewSizeAfterMatrix3DExport()
    }

    @IBAction @objc(exportDICOMFile:)
    func exportDICOMFile(_ sender: Any?) {
        setCurrentdcmExport(dcmExportMode)
        if let exportDCMWindow { window?.beginSheet(exportDCMWindow, completionHandler: nil) }
    }

    // MARK: Pictures

    /// The view's last frame, tightly packed top-down RGB with the overlay,
    /// malloc'd for the caller to free; the two eyes side by side in stereo.
    @objc(getRawPixels::::::)
    func getRawPixels(_ width: UnsafeMutablePointer<Int>, _ height: UnsafeMutablePointer<Int>, _ spp: UnsafeMutablePointer<Int>,
                      _ bpp: UnsafeMutablePointer<Int>, _ screenCapture: Bool, _ force8bits: Bool) -> UnsafeMutablePointer<UInt8>? {
        // The drawable is measured in pixels: the VTK window knows its size,
        // and the readback returns tightly packed, top-down RGB.
        spp.pointee = 3
        bpp.pointee = 8
        let mode = horosStereoMode()
        let stereo = mode == StereoMode.oneScreen.rawValue || mode == StereoMode.twoScreens.rawValue
        guard let buffer = scene.copyFrameRGB(width: width, height: height, stereo: stereo) else { return nil }
        // The text and the cube are over the surfaces, not in them.
        for case let overlay as AnnotationOverlay in subviews {
            overlay.composite(onto: buffer, width: width.pointee, height: height.pointee, originX: 0, originY: 0)
        }
        return buffer
    }

    /// The view's last frame, with the small logo at the bottom right.
    @objc(nsimage:)
    func nsimage(_ originalSize: Bool) -> NSImage {
        var width = 0, height = 0, spp = 0, bpp = 0
        let data = getRawPixels(&width, &height, &spp, &bpp, !originalSize, true)
        defer { free(data) }
        return HorosSceneView.image(rgb: data, width: width, height: height, spp: spp, bpp: bpp, logo: true)
    }

    @IBAction @objc(copy:)
    func copy(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.tiff], owner: self)
        pasteboard.setData(nsimage(false).tiffRepresentation, forType: .tiff)
    }

    // MARK: Drag and drop

    /// After a second of a still press: the view's picture, dragged.
    @objc(startDrag:)
    func startDrag(_ timer: Timer) {
        dragInProgress = true
        defer { dragInProgress = false }
        do {
            try HorosObjCException.perform {
                guard let event = timer.userInfo as? NSEvent else { return }
                let image = self.nsimage(event.modifierFlags.contains(.shift))
                let originalSize = image.size
                let ratio = originalSize.width / originalSize.height
                let thumbnail = NSImage(size: NSSize(width: 100, height: 100 / ratio), flipped: false) { bounds in
                    image.draw(in: bounds, from: NSRect(origin: .zero, size: originalSize), operation: .sourceOver, fraction: 1.0)
                    return true
                }
                let item = NSPasteboardItem()
                item.setData(image.tiffRepresentation ?? Data(), forType: .tiff)
                var flags = event.modifierFlags.rawValue
                item.setData(Data(bytes: &flags, count: MemoryLayout.size(ofValue: flags)),
                             forType: NSPasteboard.PasteboardType(SRPasteboardTypeEventModifierFlags))
                item.setDataProvider(self, forTypes: [.string, NSPasteboard.PasteboardType(kPasteboardTypeFileURLPromise as String)])
                item.setString(UTType.image.identifier, forType: NSPasteboard.PasteboardType(kPasteboardTypeFilePromiseContent as String))

                let dragging = NSDraggingItem(pasteboardWriter: item)
                let p = self.convert(event.locationInWindow, from: nil)
                dragging.setDraggingFrame(NSRect(x: p.x - thumbnail.size.width / 2, y: p.y - thumbnail.size.height / 2,
                                                 width: thumbnail.size.width, height: thumbnail.size.height), contents: thumbnail)
                let session = self.beginDraggingSession(with: [dragging], event: event, source: self)
                session.animatesToStartingPositionsOnCancelOrFail = true
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("Exception while dragging: %@", exception?.description ?? "(null)")
        }
    }

    @objc func horosSourceOperationMask() -> NSDragOperation { .generic }

    /// What the drag allows; the former -draggingSourceOperationMaskForLocal:,
    /// which Swift cannot declare, answered the same.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        horosSourceOperationMask()
    }

    // AppKit asks the data provider on the main thread; the protocol leaves
    // the requirement nonisolated.
    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        assumeMainActor((pasteboard, item, type)) { (pasteboard, item, type) in
            self.providePromisedFile(pasteboard, item, type)
        }
    }

    /// Writes the dragged picture where the drop asks for it, a JPEG named by
    /// the study and series, and gives its URL.
    private func providePromisedFile(_ pasteboard: NSPasteboard?, _ item: NSPasteboardItem, _ type: NSPasteboard.PasteboardType) {
        guard type.rawValue == kPasteboardTypeFileURLPromise as String else { return }
        var reference: Pasteboard?
        PasteboardCreate(pasteboard?.name.rawValue as CFString?, &reference)
        guard let reference else { return }
        _ = PasteboardSynchronize(reference)
        var location: CFURL?
        PasteboardCopyPasteLocation(reference, &location)
        guard let location else { return }

        let series = firstObject?.imageObj()?.series
        var description = series?.name
        if (description ?? "").isEmpty { description = series?.seriesDescription }
        // Study and series descriptions are free text from the DICOM data,
        // so they cannot become a path component unexamined.
        let name = DraggedImageFile.name(study: series?.study?.name, series: description)
        let url = DraggedImageFile.url(in: location as URL, name: name, pathExtension: "jpg")

        var flags: UInt = 0
        if let data = item.data(forType: NSPasteboard.PasteboardType(SRPasteboardTypeEventModifierFlags)),
           data.count == MemoryLayout.size(ofValue: flags) {
            (data as NSData).getBytes(&flags, length: MemoryLayout.size(ofValue: flags))
        }
        let image = nsimage(flags & NSEvent.ModifierFlags.shift.rawValue != 0)
        let jpeg = image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?
            .representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: 0.9)])

        // Advertise the file only once it exists. Naming it regardless left
        // the destination holding a path to a file that was never written.
        if let url, let jpeg, !jpeg.isEmpty, (try? jpeg.write(to: url, options: .atomic)) != nil {
            item.setString(url.absoluteString, forType: type)
        } else {
            NSLog("**** dragged image could not be written for %@", name)
        }
    }

    @objc func deleteMouseDownTimer() {
        mouseDownTimer?.invalidate()
        mouseDownTimer = nil
        dragInProgress = false
    }
}
