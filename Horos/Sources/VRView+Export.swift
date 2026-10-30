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

import AppKit
import IsiXVolumeRendering

// The exports of VRView: the DICOM export of the current image, of the
// movie's frames or of a turn around the volume; the QuickTime movies and
// their frames; the sheets that set them; the window's JPEG, TIFF, Photos and
// mail exports. A Swift extension of the class, with the same selectors.
//
// The @try/@finally of the two sheets is HorosObjCException.perform: the
// matrix layout is restored whatever happens, and an exception still goes
// where it went, to the application's handler (-reportException:), which is
// what AppKit did with one an action raised.

/// `[[sender selectedCell] tag]` of a matrix outlet, 0 for nil.
@MainActor private func selectedTag(_ matrix: NSMatrix?) -> Int {
    return matrix?.selectedCell()?.tag ?? 0
}

/// `[sender tag]`, as the Objective-C sent it to the sheet's button.
@MainActor private func senderTag(_ sender: Any?) -> Int {
    return (sender as? NSView)?.tag ?? (sender as? NSCell)?.tag ?? (sender as? NSMenuItem)?.tag ?? 0
}

/// `a / b` and `a % b` of C longs as arm64 computes them: a quotient of 0
/// and a remainder of `a` for a divisor of 0, where Swift stops.
private func cQuotient(_ a: Int, _ b: Int) -> Int { b == 0 ? 0 : a / b }
private func cRemainder(_ a: Int, _ b: Int) -> Int { b == 0 ? a : a % b }

/// The minute and the second of now, which a new series' number adds up.
private func seriesNumberMinuteAndSecond() -> Int {
    let calendar = Calendar.current
    let now = Date()
    return calendar.component(.minute, from: now) + calendar.component(.second, from: now)
}

extension VRView {

    // MARK: - Movie frames

    @objc(image4DForFrame:maxFrame:)
    func image4DForFrame(_ cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        if cur.int32Value != -1 { horos_controller?.setMovieFrame(Int(cur.int32Value)) }

        bestRenderingMode = true

        return nsimageQuicktime()
    }

    @objc(imageForFrameVR:maxFrame:)
    func imageForFrameVR(_ cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        let vtk = horos_vtk
        if cur.int32Value == -1 {
            vtk.getCameraPosition(horos_camPosition)
            vtk.getCameraViewUp(horos_camFocal)

            return nsimageQuicktime()
        }

        let frames = horos_numberOfFrames

        if max.int32Value > 36 {
            if cur.int32Value != 0 {
                if horos_verticalAngleForVR != 0 && horos_verticalAngleForVR != -90 {
                    vertical(-horos_verticalAngleForVR) // rotate to standard direction ( top of object facing right up)
                }
                if cRemainder(Int(cur.int32Value), frames) == 0 { // if need increase the vertical rotation angle
                    // Evaluating beyond 90 or -90 causes problems! Don't know why, seems it is vtk's limit.
                    if horos_verticalAngleForVR == -90 {
                        vtk.cameraRoll(Double(-horos_rotateDirectionForVR * 360 / Float(frames)))
                        // Evaluation(90)
                        vertical(-45)
                        vertical(-45)
                        horos_verticalAngleForVR -= Float(cQuotient(360, frames))
                        horos_verticalAngleForVR += 180
                        vtk.cameraAzimuth(Double(-horos_rotateDirectionForVR * 360 / Float(frames)))
                    } else {
                        horos_verticalAngleForVR -= Float(cQuotient(360, frames))
                        if horos_verticalAngleForVR < -90 { // to avoid evaluating beyond 90 or -90, rotate the camera 180 vertically
                            // Evaluation(180)
                            vertical(60)
                            vertical(60)
                            vertical(60)
                            horos_verticalAngleForVR += 180
                            horos_rotateDirectionForVR = -horos_rotateDirectionForVR
                        } else if horos_verticalAngleForVR == -90 {
                            vtk.cameraAzimuth(Double(horos_rotateDirectionForVR * 360 / Float(frames)))
                            vertical(-45)
                            vertical(-45)
                            horos_rotateDirectionForVR = -horos_rotateDirectionForVR
                        }
                    }
                }
                if horos_verticalAngleForVR != -90 {
                    // rotate camera horizontally when the top facing right up
                    vtk.cameraAzimuth(Double(horos_rotateDirectionForVR * 360 / Float(frames)))
                    if horos_verticalAngleForVR != 0 {
                        vtk.cameraElevation(Double(horos_verticalAngleForVR)) // rotate camera vertically
                    }
                } else if cRemainder(Int(cur.int32Value), frames) != 0 {
                    // if on the top or bottom use roll instead of azimuth
                    vtk.cameraRoll(Double(-horos_rotateDirectionForVR * 360 / Float(frames)))
                }
            }
        } else if cur.int32Value != 0 {
            vtk.cameraAzimuth(Double(cQuotient(360, frames)))
        }

        var center = [Double](repeating: 0, count: 3)
        vtk.getVolumeCenter(&center)
        vtk.setCameraFocalPoint(center)
        vtk.cameraOrthogonalizeViewUp()
        vtk.cameraComputeViewPlaneNormal()

        return nsimageQuicktime()
    }

    @objc(imageForFrame:maxFrame:)
    func imageForFrame(_ cur: NSNumber!, maxFrame max: NSNumber!) -> NSImage! {
        switch horos_rotationOrientation {
        case 0:
            azimuth(rotation() / max.floatValue)
        case 1:
            vertical(rotation() / max.floatValue)
        default:
            break
        }

        if let windowController = window?.windowController as? VRController, windowController.movieFrames() > 1 {
            var movieIndex = Int16(truncatingIfNeeded: cur.int32Value)
            while Int(movieIndex) >= Int(windowController.movieFrames()) {
                movieIndex = Int16(truncatingIfNeeded: Int(movieIndex) - Int(windowController.movieFrames()))
            }
            if movieIndex < 0 { movieIndex = 0 }

            windowController.setMovieFrame(Int(movieIndex))
        }

        return nsimageQuicktime()
    }

    @objc(resizeMatrix:size:)
    func resizeMatrix(_ currentImage: NSImage!, size matrixsize: Int32) -> NSImage! {
        let size = currentImage.size
        let sourceRect = NSMakeRect(0.0, 0.0, size.width, size.height)
        let imageRect: NSRect

        if size.width > size.height {
            let ratio = Float(Double(size.width) / Double(matrixsize))
            imageRect = NSMakeRect(0.0, 0.0, CGFloat(CConversion.int(Double(size.width) / Double(ratio))),
                                   CGFloat(CConversion.int(Double(size.height) / Double(ratio))))
            NSLog("ratio: %f", Double(ratio))
        } else {
            let ratio = Float(Double(size.height) / Double(matrixsize))
            imageRect = NSMakeRect(0.0, 0.0, CGFloat(CConversion.int(Double(size.width) / Double(ratio))),
                                   CGFloat(CConversion.int(Double(size.height) / Double(ratio))))
            NSLog("ratio: %f", Double(ratio))
        }

        return NSImage(size: imageRect.size, flipped: false) { bounds in
            currentImage.draw(in: bounds, from: sourceRect, operation: .copy, fraction: 1.0)
            return true
        }
    }

    @objc(nsimageQuicktime)
    func nsimageQuicktime() -> NSImage! {
        renderImage(withBestQuality: bestRenderingMode, waitDialog: false)

        let theIm = nsimage(true)

        endRenderImageWithBestQuality()

        return theIm
    }

    @objc(nsimageQuicktime:)
    func nsimageQuicktime(_ renderingModec: Bool) -> NSImage! {
        bestRenderingMode = renderingModec
        return nsimageQuicktime()
    }

    // MARK: - The DICOM export sheet

    @IBAction @objc(switchToSeriesRadio:)
    func switchToSeriesRadio(_ sender: Any?) {
        dcmExportMode?.selectCell(withTag: 1)
    }

    @objc(checkView::)
    func checkView(_ aView: NSView!, _ onOff: Bool) {
        if let control = aView as? NSControl {
            control.isEnabled = onOff
            return
        }
        // Recursively check all the subviews in the view
        for view in aView?.subviews ?? [] {
            checkView(view, onOff)
        }
    }

    @IBAction @objc(setCurrentdcmExport:)
    func setCurrentdcmExport(_ sender: Any?) {
        if (sender as? NSMatrix)?.selectedCell()?.tag == 1 {
            checkView(dcmBox, true)
        } else {
            checkView(dcmBox, false)
        }

        dcmquality?.cell(withTag: 1)?.isEnabled = true
    }

    @objc(centerRect:inRect:)
    func centerRect(_ smallRect: NSRect, inRect bigRect: NSRect) -> NSRect {
        var centerRect = NSRect.zero
        centerRect.size = smallRect.size
        centerRect.origin.x = (bigRect.size.width - smallRect.size.width) / 2.0
        centerRect.origin.y = (bigRect.size.height - smallRect.size.height) / 2.0
        return centerRect
    }

    @objc(restoreViewSizeAfterMatrix3DExport)
    dynamic func restoreSizeAfterMatrix3DExport() {
        (horos_matrixExportLayout as? VRExportLayout)?.restore()
        horos_matrixExportLayout = nil
    }

    @objc(setViewSizeToMatrix3DExport)
    dynamic func setViewSizeToMatrix3DExport() {
        restoreSizeAfterMatrix3DExport()
        let option = UserDefaults.standard.integer(forKey: "EXPORTMATRIXFOR3D")
        let pixels: CGFloat = option == 1 ? 512 : (option == 2 ? 768 : 0)
        if pixels == 0 { return }
        horos_matrixExportLayout = VRExportLayout(view: self, pixelSize: pixels)
        display()
    }

    @objc(exportDCMCurrentImage)
    func exportDCMCurrentImage() -> [AnyHashable: Any]! {
        return exportDCMCurrentImage(in16bit: true)
    }

    @objc(exportDCMCurrentImageIn16bit:)
    func exportDCMCurrentImage(in16bit fullDepth: Bool) -> [AnyHashable: Any]! {
        resetAutorotate(self)

        var width = 0, height = 0, spp = 0, bpp = 0
        var o = [Float](repeating: 0, count: 9)
        var f: String? = nil
        var offset: Int32 = 0
        var isSigned: ObjCBool = false

        if exportDCM == nil {
            exportDCM = DICOMExport()
            exportDCM.setSeriesNumber(5500)
        }

        renderImage(withBestQuality: bestRenderingMode, waitDialog: false, display: true)

        let dataPtr = getRawPixels(&width, &height, &spp, &bpp, true, !fullDepth, offset: &offset, isSigned: &isSigned)

        endRenderImageWithBestQuality()

        if let dataPtr, let exportDCM {
            exportDCM.setModalityAsSource(true)

            exportDCM.setSourceFile(horos_firstObject?.srcFile)
            exportDCM.setSeriesDescription(dcmSeriesString)

            exportDCM.setPixelData(dataPtr, samplesPerPixel: Int32(truncatingIfNeeded: spp),
                                   bitsPerSample: Int32(truncatingIfNeeded: bpp), width: width, height: height)

            exportDCM.setOffset(offset)
            exportDCM.setSigned(isSigned.boolValue)

            if horos_controller?.viewer2D()?.modality() == "PT", let firstObject = horos_firstObject {
                let slope = firstObject.appliedFactorPET2SUV() * firstObject.slope
                exportDCM.setSlope(slope)
            }
            exportDCM.setDefaultWWWL(CConversion.long(horos_ww), CConversion.long(horos_wl))

            getOrientation(&o)
            if UserDefaults.standard.bool(forKey: "exportOrientationIn3DExport") {
                exportDCM.setOrientation(&o)
            }

            let vtk = horos_vtk
            if vtk.cameraParallelProjection {
                if fullDepth {
                    var r = 1.0

                    if vtk.hasVolumeMapper {
                        r = vtk.rayCastImageInfoFused(false).sampleDistance
                    }

                    exportDCM.setPixelSpacing(Float(getResolution() * r), Float(getResolution() * r))
                } else {
                    exportDCM.setPixelSpacing(Float(getResolution()), Float(getResolution()))
                }

                if clipRangeActivated {
                    var cos = [Float](repeating: 0, count: 9)
                    getCosMatrix(&cos)
                    exportDCM.setOrientation(&cos)

                    var position = [Float](repeating: 0, count: 3)
                    getOrigin(&position)
                    exportDCM.setPosition(&position)
                    exportDCM.setSliceThickness(getClippingRangeThicknessInMm())
                }
            }

            f = exportDCM.writeDCMFile(nil)
            if f == nil {
                HorosAlertPanel.runCritical(title: NSLocalizedString("Error", comment: ""),
                                            message: NSLocalizedString("Error during the creation of the DICOM File!", comment: ""),
                                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            }

            free(dataPtr)
        }

        // +dictionaryWithObjectsAndKeys: with a nil file made an empty dictionary.
        if let f { return ["file": f] }
        return [:]
    }

    @IBAction @objc(endDCMExportSettings:)
    func endDCMExportSettings(_ sender: Any?) {
        let tag = senderTag(sender)
        exportDCMWindow?.makeFirstResponder(nil) // To force nstextfield validation.
        exportDCMWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        horos_numberOfFrames = Int(dcmframesSlider?.intValue ?? 0)
        bestRenderingMode = selectedTag(dcmquality) != 0
        horos_rotationValue = selectedTag(dcmrotation) == 1 ? 360 : 180
        horos_rotationOrientation = selectedTag(dcmorientation) == 1 ? 1 : 0

        var producedFiles: [[AnyHashable: Any]] = []

        horos_vtk.setRendererDraws(true)

        dcmSeriesString = dcmSeriesName?.stringValue

        guard tag != 0 else { return }

        let exception = HorosObjCException.caught {
            self.exportDICOMFiles(into: &producedFiles)
        }
        // @finally
        restoreSizeAfterMatrix3DExport()
        if let exception { NSApp.reportException(exception) }
    }

    /// The body of the @try of -endDCMExportSettings: (the frames exported and
    /// the files added to the database).
    private func exportDICOMFiles(into producedFiles: inout [[AnyHashable: Any]]) {
        var fullDepthCapture = false

        if dcmExportDepth?.selectedTag() == 1 && dcmExportDepth?.isEnabled == true
            && (renderingMode == 1 || renderingMode == 3 || renderingMode == 2) {
            fullDepthCapture = true
        }

        setViewSizeToMatrix3DExport()

        if fullDepthCapture {
            prepareFullDepthCapture()
        }

        let windowController = window?.windowController as? VRController
        let movieFrames = Int(windowController?.movieFrames() ?? 0)

        if selectedTag(dcmExportMode) == 0 {
            // CURRENT image only
            // Each accepted request starts a new series, even within the same second.
            exportDCM = DICOMExport()
            exportDCM.setSeriesNumber(5220 + seriesNumberMinuteAndSecond())

            producedFiles.append(exportDCMCurrentImage(in16bit: fullDepthCapture))
        } else if selectedTag(dcmExportMode) == 2 {
            // 4th dimension
            let progress = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
            progress?.showWindow(self)
            progress?.progress()?.maxValue = Double(movieFrames)

            exportDCM = DICOMExport()
            exportDCM.setSeriesNumber(5250 + seriesNumberMinuteAndSecond())

            var i = 0
            while i < Int(windowController?.movieFrames() ?? 0) {
                windowController?.setMovieFrame(i)

                producedFiles.append(exportDCMCurrentImage(in16bit: fullDepthCapture))

                progress?.increment(by: 1)
                if progress?.aborted() ?? false { break }

                resetAutorotate(self)
                i += 1
            }

            progress?.close()

            exportDCM = nil
        } else {
            // A 3D sequence
            if movieFrames > 1 {
                horos_numberOfFrames /= movieFrames
                horos_numberOfFrames *= movieFrames
            }

            let progress = Wait(string: NSLocalizedString("Creating a DICOM series", comment: ""))
            progress?.showWindow(self)
            progress?.progress()?.maxValue = Double(horos_numberOfFrames)
            progress?.setCancel(true)

            exportDCM = DICOMExport()
            exportDCM.setSeriesNumber(5500 + seriesNumberMinuteAndSecond())

            let vtk = horos_vtk
            vtk.hideCropBox()
            vtk.removeOutline()
            vtk.showCornerText(false)

            var i = 0
            while i < horos_numberOfFrames {
                let frames = Int(windowController?.movieFrames() ?? 0)
                if frames > 1 {
                    var movieIndex = Int16(truncatingIfNeeded: i)
                    while Int(movieIndex) >= frames { movieIndex = Int16(truncatingIfNeeded: Int(movieIndex) - frames) }
                    if movieIndex < 0 { movieIndex = 0 }

                    windowController?.setMovieFrame(Int(movieIndex))
                }

                producedFiles.append(exportDCMCurrentImage(in16bit: fullDepthCapture))

                progress?.increment(by: 1)

                if progress?.aborted() ?? false { break }

                switch horos_rotationOrientation {
                case 0:
                    azimuth(horos_rotationValue / Float(horos_numberOfFrames))
                case 1:
                    vertical(horos_rotationValue / Float(horos_numberOfFrames))
                default:
                    break
                }
                i += 1
            }

            endRenderImageWithBestQuality()

            progress?.close()

            exportDCM = nil
        }

        if fullDepthCapture {
            restoreFullDepthCapture()
        }

        if !producedFiles.isEmpty {
            HorosSceneView.importExportedFiles(producedFiles.compactMap { $0["file"] as? String })
        }
    }

    @IBAction @objc(endQuicktimeSettings:)
    func endQuicktimeSettings(_ sender: Any?) {
        let tag = senderTag(sender)
        export3DWindow?.orderOutAndEndSheet(returnCode: NSApplication.ModalResponse(rawValue: tag))

        horos_numberOfFrames = Int(framesSlider?.intValue ?? 0)
        bestRenderingMode = selectedTag(quality) != 0

        horos_rotationValue = selectedTag(rotationMatrix) == 1 ? 360 : 180
        horos_rotationOrientation = selectedTag(orientation) == 1 ? 1 : 0

        guard tag != 0 else { return }

        let exception = HorosObjCException.caught {
            let windowController = self.window?.windowController as? VRController
            let movieFrames = Int(windowController?.movieFrames() ?? 0)
            if movieFrames > 1 {
                self.horos_numberOfFrames /= movieFrames
                self.horos_numberOfFrames *= movieFrames
            }

            self.setViewSizeToMatrix3DExport()

            let mov = QuicktimeExport(selector: self, #selector(VRView.imageForFrame(_:maxFrame:)), self.horos_numberOfFrames)
            let name = (self.horos_controller?.fileList()?.first as AnyObject?)?.value(forKeyPath: "series.study.name") as? String
            mov?.createMovieQTKit(true, false, name)
        }
        // @finally
        restoreSizeAfterMatrix3DExport()
        if let exception { NSApp.reportException(exception) }
    }

    @objc(exportDICOM)
    func exportDICOM() {
        guard let exportDCMWindow else {
            HorosAlertPanel.run(title: NSLocalizedString("Not available", comment: ""),
                                message: NSLocalizedString("This function is not available for this window.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }

        horos_vtk.setRendererDraws(false)

        setCurrentdcmExport(dcmExportMode)

        let movieFrames = (window?.windowController as? VRController)?.movieFrames() ?? 0
        dcmExportMode?.cell(withTag: 2)?.isEnabled = movieFrames > 1

        dcmExportDepth?.isEnabled = renderingMode == 1 || renderingMode == 3 || renderingMode == 2
        window?.beginSheet(exportDCMWindow, completionHandler: nil)
    }

    // MARK: - QuickTime

    @IBAction @objc(exportQuicktime:)
    func exportQuicktime(_ sender: Any?) {
        if export3DWindow == nil {
            HorosAlertPanel.run(title: NSLocalizedString("Not available", comment: ""),
                                message: NSLocalizedString("This function is not available for this window.", comment: ""),
                                defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
        }

        quality?.cell(withTag: 1)?.isEnabled = true

        let movieFrames = horos_controller?.movieFrames() ?? 0
        if movieFrames > 1 {
            if HorosAlertPanel.runInformational(title: NSLocalizedString("Quicktime Export", comment: ""),
                                                message: NSLocalizedString("Should I export the temporal series or the 3D scene?", comment: ""),
                                                defaultButton: NSLocalizedString("3D Scene", comment: ""),
                                                alternateButton: NSLocalizedString("Temporal Series", comment: ""),
                                                otherButton: nil) == HorosAlertDefaultResponse {
                if let export3DWindow { window?.beginSheet(export3DWindow, completionHandler: nil) }
            } else {
                let mov = QuicktimeExport(selector: self, #selector(VRView.image4DForFrame(_:maxFrame:)), Int(movieFrames))
                let name = (horos_controller?.fileList()?.first as AnyObject?)?.value(forKeyPath: "series.study.name") as? String
                mov?.createMovieQTKit(true, false, name)
            }
        } else if let export3DWindow {
            window?.beginSheet(export3DWindow, completionHandler: nil)
        }
    }

    // MARK: - The window's exports

    @objc(sendMail:)
    func sendMail(_ sender: Any?) {
        horos_vtk.setRendererDraws(false)
        horos_controller?.sendMail(sender)
        horos_vtk.setRendererDraws(true)
    }

    @objc(exportJPEG:)
    func exportJPEG(_ sender: Any?) {
        horos_vtk.setRendererDraws(false)
        horos_controller?.exportJPEG(sender)
        horos_vtk.setRendererDraws(true)
    }

    @objc(export2iPhoto:)
    func export2iPhoto(_ sender: Any?) {
        horos_vtk.setRendererDraws(false)
        horos_controller?.export2iPhoto(sender)
        horos_vtk.setRendererDraws(true)
    }

    @objc(exportTIFF:)
    func exportTIFF(_ sender: Any?) {
        horos_vtk.setRendererDraws(false)
        horos_controller?.exportTIFF(sender)
        horos_vtk.setRendererDraws(true)
    }
}
