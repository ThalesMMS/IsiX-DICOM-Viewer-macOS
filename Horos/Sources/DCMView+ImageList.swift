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
import IsiXDICOMFile

// The series a DCMView shows and the image on screen: the lists of pixels,
// files and ROIs it is given, the index that picks the image, and what follows
// the choice (the image's ROIs, its window, its presentation state, the age
// shown). The rules that need neither the view nor AppKit are IsiXImaging's
// SeriesDisplay.

extension DCMView {

    // MARK: - The image shown

    /// The image at the index, clamped to the series, with the window, zoom and
    /// pan of the image or the series reset; -1 or no series clears the view.
    @objc(setIndexWithReset::)
    public dynamic func setIndexWithReset(_ index: Int, _ sizeToFit: Bool) {
        if let dcmPixList = self.horos_dcmPixList, index >= 0 {
            self.window?.acceptsMouseMovedEvents = true

            self.horos_curROI = nil

            self.horos_curImage = SeriesDisplay.clampedIndex(index, count: dcmPixList.count)

            self.curDCM = (dcmPixList.object(at: Int(self.horos_curImage)) as! DCMPix)

            if let dcmRoiList = self.horos_dcmRoiList {
                self.horos_curRoiList = (dcmRoiList.object(at: Int(self.horos_curImage)) as! NSMutableArray)
            } else {
                self.horos_curRoiList = NSMutableArray(capacity: 0)
            }

            for case let r as ROI in self.horos_curRoiList {
                r.curView = self
                r.recompute()
                // Unselect previous ROIs
                r.roImode = Int(ROI_sleep)
            }

            let curDCM: DCMPix = self.curDCM
            self.horos_curWL = curDCM.wl
            self.horos_curWW = curDCM.ww
            self.horos_curWLWWSUVConverted = curDCM.suvConverted
            self.horos_curWLWWSUVFactor = 1.0
            if self.horos_curWLWWSUVConverted && self.is2DViewer() {
                self.horos_curWLWWSUVFactor = viewerMessages(self.windowController())?.viewerFactorPET2SUV() ?? 0
            }

            self.horos_origin.x = 0
            self.horos_origin.y = 0
            self.horos_scaleValue = 1

            // get Presentation State info from series Object
            self.updatePresentationStateFromSeries()

            curDCM.checkImageAvailble(self.horos_curWW, self.horos_curWL)

            if sizeToFit && self.is2DViewer() == false {
                self.scaleToFit()
            }

            self.loadTextures()
            self.needsDisplay = true

            self.updateYearOld()

            if self.is2DViewer() {
                let controller = self.windowController() as AnyObject?
                controller?.willChangeValue(forKey: "thicknessInMm")
                controller?.didChangeValue(forKey: "thicknessInMm")
            }
        } else {
            self.curDCM = nil
            self.horos_curImage = -1
            self.horos_curRoiList = nil
            self.horos_curROI = nil
            self.loadTextures()
        }
    }

    /// The pixels, files and ROI lists of a series. A new pixel list cancels a
    /// pending length and the slab scroll's remainder, and decides whether the
    /// series is a volume; with reset, the first image is shown and the series'
    /// presentation state restored.
    @objc(setPixels:files:rois:firstImage:level:reset:)
    public dynamic func setPixels(_ pixels: NSMutableArray!, files: NSArray!, rois: NSMutableArray!, firstImage: Int, level: CChar, reset: Bool) {
        self.horosDiscardScrollPreview()
        DCMView.horos_static_drawLock?.lock()

        // The caller's array itself, not a bridged copy: the view lists the
        // files the viewer lists, as the instance variable did.
        inputLogException(inputCatch {
            if self.is2DViewer() {
                let defaults = UserDefaults.standard
                self.horos_currentToolRight = ToolMode(rawValue: Int16(truncatingIfNeeded: defaults.integer(forKey: "DEFAULTRIGHTTOOL"))) ?? .tWL

                if defaults.bool(forKey: "RestoreLeftMouseTool") {
                    self.horos_currentTool = ToolMode(rawValue: Int16(truncatingIfNeeded: defaults.integer(forKey: "DEFAULTLEFTTOOL"))) ?? .tWL
                }
            }

            self.curDCM = nil

            self.horos_volumicData = -1

            self.horos_cleanedOutDcmPixArray = nil

            if self.horos_dcmPixList !== pixels {
                self.cancelLengthPlacement()
                self.horos_slabScrollRemainder = 0
                self.horos_slabScrollTimestamp = 0
                self.horos_dcmPixList = pixels

                self.horos_volumicSeries = true

                if let files, files.count > 0 {
                    let sopClassUID = (files.object(at: 0) as AnyObject).value(forKeyPath: "series.seriesSOPClassUID") as? String
                    if !(DICOMSOPClass.isImageStorage(sopClassUID) || DICOMSOPClass.isRadiotherapy(sopClassUID)
                         || DICOMSOPClass.isStructuredReport(sopClassUID) || sopClassUID == nil) {
                        NSLog("*** DCMView ! ****** It's not a DICOM image ? SOP Class UID: %@", sopClassUID ?? "")
                    }
                }

                if self.horos_stringID != "previewDatabase" {
                    let list = self.horos_dcmPixList
                    let first = list?.firstObject as? DCMPix, last = list?.lastObject as? DCMPix
                    self.horos_volumicSeries = SeriesDisplay.isVolume(count: list?.count ?? 0,
                                                                      firstSliceLocation: first?.sliceLocation ?? 0,
                                                                      lastSliceLocation: last?.sliceLocation ?? 0)
                }
            }

            if self.horos_dcmFilesList !== files {
                self.horos_dcmFilesList = files
            }

            self.horos_flippedData = false

            if self.horos_dcmRoiList !== rois {
                self.horos_dcmRoiList = rois
            }

            self.horos_listType = level

            if self.horos_dcmPixList != nil {
                if reset {
                    self.setIndexWithReset(firstImage, true)
                    self.updatePresentationStateFromSeries()
                }
            }

            self.needsDisplay = true
        }, "-[DCMView setPixels:files:rois:firstImage:level:reset:]")

        DCMView.horos_static_drawLock?.unlock()
    }

    @objc(setDCM::::::)
    public dynamic func setDCM(_ c: NSMutableArray!, _ d: NSArray!, _ e: NSMutableArray!, _ firstImage: Int, _ type: CChar, _ reset: Bool) {
        self.setPixels(c, files: d, rois: e, firstImage: firstImage, level: type, reset: reset)
    }

    /// The image at the index, clamped to the series: its ROIs, its window
    /// (that of the view, unless the series keeps each image's own), the age
    /// shown, the mouse values, the tiles.
    @objc(setIndex:)
    public dynamic func setIndex(_ index: Int) {
        DCMView.horos_static_drawLock?.lock()

        inputLogException(inputCatch {
            self.stopROIEditing()

            self.window?.acceptsMouseMovedEvents = true

            if let dcmPixList = self.horos_dcmPixList, index > -1, dcmPixList.count > 0 {
                let firstPath = ((self.horos_dcmFilesList?.object(at: 0) as AnyObject?)?.value(forKey: "completePath") as? NSString)?.lastPathComponent
                self.horos_noScale = firstPath == "Empty.tif"

                self.horos_curImage = SeriesDisplay.clampedIndex(index, count: dcmPixList.count)

                // The former image is released after the new one is loaded, which
                // keeps the cached group of a multi-frame image.
                let formerPix = self.curDCM
                self.curDCM = (dcmPixList.object(at: Int(self.horos_curImage)) as! DCMPix)

                self.curDCM.checkLoad()

                withExtendedLifetime(formerPix) {}

                if let dcmRoiList = self.horos_dcmRoiList {
                    self.horos_curRoiList = (dcmRoiList.object(at: Int(self.horos_curImage)) as! NSMutableArray)
                } else {
                    self.horos_curRoiList = NSMutableArray(capacity: 0)
                }

                var keepIt = false
                for case let r as ROI in self.horos_curRoiList {
                    r.curView = self
                    r.recompute()
                    if self.horos_curROI === r { keepIt = true }
                }

                if keepIt == false {
                    self.horos_curROI = nil
                }

                var done = false

                if self.is2DViewer() {
                    if self.horos_curImage >= 0 && self.horos_COPYSETTINGSINSERIES == false {
                        self.applyWindowLevelOfImage()

                        self.updatePresentationState(fromSeriesOnlyImageLevel: true)

                        done = true
                    }

                    let controller = self.windowController() as AnyObject?
                    controller?.willChangeValue(forKey: "thicknessInMm")
                    controller?.didChangeValue(forKey: "thicknessInMm")
                }

                if done == false {
                    self.applyWindowLevelOfImage()
                }

                self.loadTextures()

                self.updateYearOld()

                NotificationCenter.default.post(name: .OsirixDCMViewIndexChanged, object: self)
            } else {
                self.curDCM = nil
                self.horos_curImage = -1
                self.horos_curRoiList = nil
                self.horos_curROI = nil
                self.loadTextures()
            }

            let event = NSApplication.shared.currentEvent

            self.mouseMovedEvent(event)
            self.needsDisplay = true

            self.updateTilingViews()
        }, "-[DCMView setIndex:]")

        DCMView.horos_static_drawLock?.unlock()
    }

    /// The view's window applied to the new image when it differs from the
    /// image's own or the image has one to apply; else the image is only made
    /// available with it.
    private func applyWindowLevelOfImage() {
        let curDCM: DCMPix = self.curDCM
        if self.horos_curWW != curDCM.ww || self.horos_curWL != curDCM.wl || curDCM.updateToApply() == true {
            self.reapplyWindowLevel()
        } else {
            curDCM.checkImageAvailble(self.horos_curWW, self.horos_curWL)
        }
    }

    /// -mouseMoved: sent with the current event, which may be nil, as the
    /// Objective-C sent it.
    private func mouseMovedEvent(_ event: NSEvent?) {
        let send = unsafeBitCast(self.method(for: #selector(NSResponder.mouseMoved(with:))),
                                 to: (@convention(c) (AnyObject, Selector, NSEvent?) -> Void).self)
        send(self, #selector(NSResponder.mouseMoved(with:)), event)
    }

    /// The patient's age shown with the image, and at acquisition when different.
    private func updateYearOld() {
        let file = self.horos_dcmFilesList?.object(at: Int(self.horos_curImage)) as AnyObject?
        let now = file?.value(forKeyPath: "series.study.yearOld") as? String
        let acquisition = file?.value(forKeyPath: "series.study.yearOldAcquisition") as? String
        self.yearOld = SeriesDisplay.ageText(now: now, atAcquisition: acquisition)
    }

    // MARK: - Notifications

    /// Another view shows a 3D point on this series: its image, and the mark.
    @objc(Display3DPoint:)
    public dynamic func display3DPoint(_ note: NSNotification!) {
        if self.horos_stringID == nil {
            let v = note?.object as AnyObject?

            if v === self.horos_dcmPixList {
                let userInfo = note?.userInfo as NSDictionary?
                let x = DCMViewSettings.intValue(userInfo?.value(forKey: "x"))
                let y = DCMViewSettings.intValue(userInfo?.value(forKey: "y"))
                let z = DCMViewSettings.intValue(userInfo?.value(forKey: "z"))
                self.horos_display2DPoint.x = CGFloat(x)
                self.horos_display2DPoint.y = CGFloat(y)
                self.horos_display2DPointIndex = z

                self.setIndex(Int(truncatingIfNeeded: z))

                self.sendSyncMessage(0)
                self.needsDisplay = true
            }
        }
    }

    /// A tile of the same mosaic changed its image: this one takes its window,
    /// zoom and pan.
    @objc(updateCurrentImage:)
    public dynamic func updateCurrentImage(_ note: NSNotification!) {
        if self.horos_stringID == nil {
            let otherView = note?.object as? NSView
            let sameSuperview = otherView?.superview?.isEqual(self.superview) ?? false
            let notSelf = !(otherView?.isEqual(self) ?? false)

            if sameSuperview && notSelf {
                self.setImageParamatersFrom(otherView as? DCMView)
            }
        }
    }

    // MARK: - 12-bit LUT

    @objc(setIsLUT12Bit:)
    public dynamic func setIsLUT12Bit(_ boo: Bool) {
        for case let pix as DCMPix in (self.horos_dcmPixList ?? NSMutableArray()) {
            pix.isLUT12Bit = boo
        }
    }

    /// Whether every image of the series has its 12-bit LUT on.
    @objc(isLUT12Bit)
    public dynamic func isLUT12Bit() -> Bool {
        var is12Bit = true
        for case let pix as DCMPix in (self.horos_dcmPixList ?? NSMutableArray()) {
            is12Bit = is12Bit && pix.isLUT12Bit
        }
        return is12Bit
    }
}
