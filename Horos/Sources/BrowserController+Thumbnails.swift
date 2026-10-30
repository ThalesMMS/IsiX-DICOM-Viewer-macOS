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
import IsiXDatabase

// The thumbnails' preview: the frames the preview reads, the animation slider
// for the selected row, and a frame a 2D viewer has already loaded, lent to the
// preview when it is the same file, frame and series. What decides without the
// app's classes is IsiXDatabase's PreviewAnimation and PreviewReuse. The
// selectors are those of the former Objective-C methods.

/// [value intValue]: 0 for nil and for what is neither a number nor a string.
private func intValue(_ value: Any?) -> Int32 {
    if let number = value as? NSNumber { return number.int32Value }
    if let string = value as? NSString { return string.intValue }
    return 0
}

/// The identity of a database image's frame, as the preview asks for it and as
/// a viewer holds it: path, instance, series, class, modality, frame, size.
private func previewFrame(of image: NSObject, frame: Int32) -> PreviewFrame {
    PreviewFrame(path: image.value(forKey: "completePath") as? String ?? "",
                 sopInstanceUID: image.value(forKey: "sopInstanceUID") as? String ?? "",
                 seriesInstanceUID: image.value(forKeyPath: "series.seriesDICOMUID") as? String ?? "",
                 sopClassUID: image.value(forKeyPath: "series.seriesSOPClassUID") as? String ?? "",
                 modality: image.value(forKeyPath: "series.modality") as? String ?? "",
                 frameNumber: Int(frame), frameCount: Int(intValue(image.value(forKey: "numberOfFrames"))),
                 rows: Int(intValue(image.value(forKey: "height"))), columns: Int(intValue(image.value(forKey: "width"))),
                 seriesID: Int(intValue(image.value(forKeyPath: "series.id"))))
}

extension BrowserController {

    /// The identity the preview asks for, built from the database row alone.
    @objc(horos_previewFrameForImage:frame:)
    nonisolated static func horos_previewFrame(for image: DicomImage?, frame: Int32) -> PreviewFrame? {
        guard let image else { return nil }
        return previewFrame(of: image, frame: frame)
    }

    @objc(previewPix:)
    nonisolated func previewPix(_ i: Int32) -> DCMPix! {
        BrowserObjC.synchronized(horos_previewPixThumbnails) {
            (horos_previewPix as NSArray?)?.object(at: Int(i)) as? DCMPix
        }
    }

    @objc(initAnimationSlider)
    func initAnimationSlider() {
        let slider = horos_animationSlider

        guard var cell = horos_oMatrix?.selectedCell() as? NSButtonCell else {
            disableAnimation(slider)
            resetPreviewToSlider(slider)
            return
        }
        if cell.tag >= (horos_matrixViewArray as NSArray?)?.count ?? 0 {
            horos_oMatrix?.selectCell(withTag: 0)
            guard let first = horos_oMatrix?.selectedCell() as? NSButtonCell else {
                // [nil tag] is 0: the thumbnail of the first row.
                return animate(slider, tag: 0)
            }
            cell = first
        }
        animate(slider, tag: cell.tag)
    }

    private func animate(_ slider: NSSlider?, tag: Int) {
        let outline = horos_databaseOutline
        let file = outline?.item(atRow: outline?.selectedRow ?? -1) as? NSObject
        let images = { (file?.value(forKey: "images") as? NSSet)?.allObjects ?? [] }

        let frames = PreviewAnimation.frames(
            type: file?.value(forKey: "type"),
            seriesImageCount: { images().count },
            firstImageFrames: { (images().first as? NSObject)?.value(forKey: "numberOfFrames") },
            studyImages: {
                let views = horos_matrixViewArray as NSArray?
                guard (views?.count ?? 0) != 0, let study = views?.object(at: tag),
                      let images = self.imagesArray(study) as NSArray? else { return nil }
                return (images.count, { images.count > 0 ? (images.object(at: 0) as? NSObject)?.value(forKey: "numberOfFrames") : nil })
            })

        switch frames {
        case .refresh:
            outlineViewRefresh()
            refreshMatrix(self)
            return
        case .slider(let animate, let count):
            switch PreviewAnimation.sliderChange(animate: animate, sliderEnabled: slider?.isEnabled ?? false, images: count) {
            case .disable:
                disableAnimation(slider)
            case .enable(let images):
                slider?.isEnabled = true
                slider?.maxValue = Double(images - 1)
                slider?.numberOfTickMarks = images
                slider?.intValue = 0
            case .keep:
                break
            }
        }
        resetPreviewToSlider(slider)
    }

    private func disableAnimation(_ slider: NSSlider?) {
        slider?.isEnabled = false
        slider?.maxValue = 0
        slider?.numberOfTickMarks = 1
        slider?.intValue = 0
    }

    /// The preview shows the slider's image, from its first frame.
    private func resetPreviewToSlider(_ slider: NSSlider?) {
        BrowserController.horos_withReset = true
        previewSliderAction(slider)
        BrowserController.horos_withReset = false
    }

    @objc(getDCMPixFromViewerIfAvailable:frameNumber:)
    nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32) -> DCMPix! {
        getDCMPix(fromViewerIfAvailable: pathToFind, frameNumber: frameNumber, expectedFrame: nil)
    }

    /// A copy of a frame a 2D viewer has loaded, when it is the frame asked
    /// for: the same file and frame, and, given the frame expected, the same
    /// instance, series and size. Frame 0 used to match on the path alone; a
    /// multiframe file is one row per frame in a viewer's file list, so that
    /// returned whichever frame of the file the viewer happened to hold. A file
    /// rewritten, replaced or removed since the viewer decoded it is not lent.
    /// Main thread only: elsewhere, nil.
    @objc(getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:)
    nonisolated func getDCMPix(fromViewerIfAvailable pathToFind: String!, frameNumber: Int32, expectedFrame: PreviewFrame!) -> DCMPix! {
        guard Thread.isMainThread else { return nil }
        // Built and returned on the main thread, which the check above holds.
        nonisolated(unsafe) var returnPix: DCMPix?
        nonisolated(unsafe) let expectedFrame = expectedFrame
        MainActor.assumeIsolated {

            for case let viewer as ViewerController in (ViewerController.get2DViewers() as NSArray?) ?? NSArray() where !viewer.windowWillClose() {
                // The lists are copied: the viewer may change them meanwhile.
                var fileList: NSArray?
                var pixList: NSArray?
                if let raised = BrowserObjC.attempt({
                    fileList = (viewer.fileList() as NSArray?)?.copy() as? NSArray
                    pixList = (viewer.pixList() as NSArray?)?.copy() as? NSArray
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:]")
                }
                let volumeData = viewer.volumeData()

                if let raised = BrowserObjC.attempt({
                    var index = PreviewReuse.index(count: fileList?.count ?? 0,
                                                   path: { (fileList?.object(at: $0) as? NSObject)?.value(forKey: "completePath") },
                                                   frame: { (fileList?.object(at: $0) as? NSObject)?.value(forKey: "frameID") },
                                                   pathToFind: pathToFind, frameNumber: frameNumber)

                    if let found = index, let expectedFrame, let image = fileList?.object(at: found) as? NSObject {
                        // The identity of what is loaded elsewhere, against what
                        // was asked for: same file, same frame, same series, same size.
                        let loaded = previewFrame(of: image, frame: intValue(image.value(forKey: "frameID")))
                        if let refusal = PreviewIdentity.refusalForReusing(loaded, asRequested: expectedFrame) {
                            NSLog("Preview: not reusing a loaded frame: %@", refusal)
                            index = nil
                        }
                    }

                    guard let found = index, let dcmPix = pixList?.object(at: found) as? DCMPix else { return }
                    dcmPix.checking?.lock()
                    dcmPix.checkLoad()

                    if dcmPix.isLoaded() && !dcmPix.loadedFileMatchesDisk() {
                        let refusal = FileRevision.refusalForReusingFile(loaded: dcmPix.loadedFileRevision() as? FileRevision,
                                                                         current: FileRevision(path: pathToFind ?? ""))
                        NSLog("Preview: not reusing a loaded frame: %@", refusal ?? "the file changed on disk")
                    } else if dcmPix.isLoaded() {
                        if let copy = dcmPix.copy() as? DCMPix {
                            let count = Int(dcmPix.pheight * dcmPix.pwidth)
                            if let pixels = malloc(count * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) {
                                if let source = dcmPix.fImage { pixels.update(from: source, count: count) }
                                copy.fImage = pixels
                                copy.freefImage(whenDone: true)
                                returnPix = copy
                            }
                        }
                    }
                    dcmPix.checking?.unlock()
                }) {
                    BrowserObjC.log(raised, stack: true, "-[BrowserController getDCMPixFromViewerIfAvailable:frameNumber:expectedFrame:]")
                }
                withExtendedLifetime(volumeData) {}
            }
        }
        return returnPix
    }
}
