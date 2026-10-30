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
import IsiXImaging

// The key images of the 2D viewer: the check box and the shortcut that mark
// the image shown, marking all images, none, or those with ROIs, the "next"
// and "previous key image" buttons (which move to another series of the study
// when this one has no further key image), showing only the key images, and
// the state of the check box. A series made by post processing has no key
// images. Which way the buttons look and where they land is IsiXImaging's
// KeyImageSearch. The selectors are those of the former Objective-C methods.

public extension ViewerController {

    /// The key image check box: marks the image shown as its state says.
    @objc(keyImageCheckBox:)
    func keyImageCheckBox(_ sender: Any!) {
        guard !horos_postprocessed else { return }

        let flag = NSNumber(value: objcBool(ViewerSender.state(sender)))
        currentImageFile()?.setValue(flag, forKey: "isKeyImage")

        if let browser = BrowserController.currentBrowser(), browser.isCurrentDatabaseBonjour {
            (browser.database as? RemoteDicomDatabase)?.object(currentImageFile(), setValue: flag, forKey: "isKeyImage")
        }

        willChangeValue(forKey: "KeyImageCounter")
        didChangeValue(forKey: "KeyImageCounter")

        buildMatrixPreview(false)

        horos_imageView?.needsDisplay = true

        saveDatabase()
    }

    /// The "next" (tag 0) and "previous" key image buttons: the next key
    /// image of the series shown, or else the first one of the next series of
    /// the study that has key images (beeping when there is none).
    @objc(findNextPreviousKeyImage:)
    func findNextPreviousKeyImage(_ sender: Any!) {
        if horos_postprocessed {
            alertPostProcessed()
            return
        }

        checkEverythingLoaded()

        let isPrevious = objcBool(ViewerSender.tag(sender))
        let flipped = horos_imageView?.flippedData ?? false
        let movie = Int(horos_curMovieIndex)
        let current = Int(horos_imageView?.curImage ?? 0)
        let fileCount = horos_fileList(at: movie)?.count ?? 0

        let inSeries = KeyImageSearch.runsForward(isPrevious: isPrevious, flipped: flipped)
            ? KeyImageSearch.firstKeyImage(in: stride(from: current + 1, to: fileCount, by: 1), isKey: isKeyImageFile)
            : KeyImageSearch.firstKeyImage(in: stride(from: current - 1, through: 0, by: -1), isKey: isKeyImageFile)
        if let index = inSeries {
            show(keyImage: index)
            return
        }

        // Nothing found: the next (or previous) series of the study.
        let browser = BrowserController.currentBrowser()
        let seriesObject = horos_imageView?.seriesObj()
        let seriesArray = (browser?.childrenArray(seriesObject?.value(forKey: "study")) as NSArray?) ?? NSArray()
        let nextSeries = !isPrevious
        let position = seriesArray.index(of: seriesObject as Any)
        if position != NSNotFound {
            // Next walks the later series in order, previous the earlier ones
            // backwards, and each stops at its end of the list.
            let step = nextSeries ? 1 : -1
            var i = position + step
            while nextSeries ? i < seriesArray.count : i >= 0 {
                let candidate = seriesArray.object(at: i)
                if ((candidate as? DicomSeries)?.keyImages()?.count ?? 0) > 0 {
                    _ = browser?.loadSeries(candidate as? NSManagedObject, self, true, keyImagesOnly: horos_displayOnlyKeyImages)

                    showCurrentThumbnail(self)
                    updateNavigator()

                    let count = horos_fileList(at: Int(horos_curMovieIndex))?.count ?? 0
                    let landing = KeyImageSearch.startsFromLastImage(nextSeries: nextSeries, flipped: horos_imageView?.flippedData ?? false)
                        ? KeyImageSearch.firstKeyImage(in: stride(from: count - 1, through: 0, by: -1), isKey: isKeyImageFile)
                        : KeyImageSearch.firstKeyImage(in: 0..<count, isKey: isKeyImageFile)
                    if let index = landing {
                        show(keyImage: index)
                        return
                    }
                }
                i += step
            }
        }

        NSSound.beep()
    }

    /// The "all images" / "key images only" popup: reopens the series with
    /// all its images, or only with its key images (an alert, and back to all
    /// images, when it has none).
    @objc(keyImageDisplayButton:)
    func keyImageDisplayButton(_ sender: Any!) {
        if horos_postprocessed {
            alertPostProcessed()
            return
        }

        let series = currentImageFile()?.value(forKey: "series")

        checkEverythingLoaded()

        horos_displayOnlyKeyImages = objcBool(horos_keyImagePopUpButton?.indexOfSelectedItem ?? 0)
        guard let series else { return }

        let browser = BrowserController.currentBrowser()
        let images = browser?.childrenArray(series) ?? []
        if !horos_displayOnlyKeyImages {
            _ = browser?.openViewer(fromImages: [images], movie: false, viewer: self, keyImagesOnly: horos_displayOnlyKeyImages)
        } else {
            let keyImages = images.filter { ((($0 as AnyObject).value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false) }

            if keyImages.isEmpty {
                HorosAlertPanel.run(title: NSLocalizedString("Key Images", comment: ""),
                                    message: NSLocalizedString("No key images have been selected in this series.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                horos_keyImagePopUpButton?.selectItem(at: 0)
            } else {
                _ = browser?.openViewer(fromImages: [keyImages], movie: false, viewer: self, keyImagesOnly: horos_displayOnlyKeyImages)
            }
        }
    }

    /// Marks as key images the images that have ROIs, in every frame.
    @objc(setROIsImagesKeyImages:)
    func setROIsImagesKeyImages(_ sender: Any!) {
        if horos_postprocessed {
            alertPostProcessed()
            return
        }

        let yes = NSNumber(value: true)
        markImagesWithROIs { $0.setValue(yes, forKey: "isKeyImage") }

        if let browser = BrowserController.currentBrowser(), browser.isCurrentDatabaseBonjour {
            markImagesWithROIs { (browser.database as? RemoteDicomDatabase)?.object($0, setValue: yes, forKey: "isKeyImage") }
        }

        buildMatrixPreview(false)
        horos_imageView?.needsDisplay = true
        saveDatabase()

        adjustKeyImage()
    }

    /// Unmarks every image of every frame.
    @objc(setAllNonKeyImages:)
    func setAllNonKeyImages(_ sender: Any!) {
        setEveryImage(asKeyImage: false)
    }

    /// Marks every image of every frame.
    @objc(setAllKeyImages:)
    func setAllKeyImages(_ sender: Any!) {
        setEveryImage(asKeyImage: true)
    }

    /// The key image shortcut: toggles the check box and applies it.
    @objc(setKeyImage:)
    func setKeyImage(_ sender: Any!) {
        if horos_postprocessed {
            alertPostProcessed()
            return
        }

        guard let check = keyImageCheck else {
            keyImageCheckBox(nil)
            return
        }
        check.state = check.state.rawValue == 0 ? .on : .off
        keyImageCheckBox(check)
    }

    /// The check box and the popup: disabled for a post processed series,
    /// otherwise enabled, the box showing whether the image shown is a key
    /// image.
    @objc(adjustKeyImage)
    func adjustKeyImage() {
        if horos_postprocessed {
            keyImageCheck?.isEnabled = false
            horos_keyImagePopUpButton?.isEnabled = false
            return
        }

        // Multiframes keep the controls enabled: a key image of a multiframe
        // marks the file (a sequence or a series) and is still useful, and
        // the popup goes back to "all images" elsewhere when all the images
        // are key images.
        keyImageCheck?.isEnabled = true
        horos_keyImagePopUpButton?.isEnabled = true

        let current = Int(horos_imageView?.curImage ?? 0)
        if current >= 0 && isKeyImageFile(current) {
            keyImageCheck?.state = .on
        } else {
            keyImageCheck?.state = .off
        }
    }

    /// Whether image `index` of the frame shown is a key image (never in a
    /// post processed series).
    @objc(isKeyImage:)
    func isKeyImage(_ index: Int32) -> Bool {
        if horos_postprocessed { return false }
        return isKeyImageFile(Int(index))
    }

    @objc(displayOnlyKeyImages)
    func displayOnlyKeyImages() -> Bool {
        horos_displayOnlyKeyImages
    }
}

extension ViewerController {

    /// A value read as Objective-C's BOOL reads it: any non-zero value on
    /// arm64, the low byte on x86_64.
    fileprivate func objcBool(_ value: Int) -> Bool {
        #if arch(x86_64)
        return Int8(truncatingIfNeeded: value) != 0
        #else
        return value != 0
        #endif
    }

    /// The file of the image shown.
    fileprivate func currentImageFile() -> NSManagedObject? {
        horos_fileList(at: Int(horos_curMovieIndex))?.object(at: Int(horos_imageView?.curImage ?? 0)) as? NSManagedObject
    }

    /// Whether file `index` of the frame shown is marked as a key image.
    fileprivate func isKeyImageFile(_ index: Int) -> Bool {
        let file = horos_fileList(at: Int(horos_curMovieIndex))?.object(at: index) as AnyObject?
        return (file?.value(forKey: "isKeyImage") as? NSNumber)?.boolValue ?? false
    }

    /// Shows image `index` of the series and synchronizes the other viewers.
    fileprivate func show(keyImage index: Int) {
        horos_imageView?.setIndex(Int(truncatingIfNeeded: index))
        horos_imageView?.sendSyncMessage(0)
        adjustSlider()
        horos_imageView?.displayIfNeeded()
    }

    fileprivate func alertPostProcessed() {
        HorosAlertPanel.run(title: NSLocalizedString("Key Images", comment: ""),
                            message: NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", comment: ""),
                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    fileprivate func saveDatabase() {
        _ = BrowserController.currentBrowser()?.database?.save(nil)
    }

    /// Calls `mark` for each file whose image has ROIs, in every frame.
    fileprivate func markImagesWithROIs(_ mark: (NSManagedObject) -> Void) {
        for x in 0..<Int(horos_maxMovieIndex) {
            guard let files = horos_fileList(at: x) else { continue }
            for i in 0..<files.count {
                let file = files.object(at: i) as! NSManagedObject
                if ((horos_roiList(at: x)?.object(at: i) as? NSArray)?.count ?? 0) > 0 {
                    mark(file)
                }
            }
        }
    }

    /// Marks or unmarks every image of every frame, then refreshes the
    /// thumbnails, the view, the database and the check box.
    fileprivate func setEveryImage(asKeyImage key: Bool) {
        if horos_postprocessed {
            alertPostProcessed()
            return
        }

        let value = NSNumber(value: key)
        for x in 0..<Int(horos_maxMovieIndex) {
            for case let file as NSManagedObject in horos_fileList(at: x) ?? NSMutableArray() {
                file.setValue(value, forKey: "isKeyImage")
            }
        }

        if let browser = BrowserController.currentBrowser(), browser.isCurrentDatabaseBonjour {
            for x in 0..<Int(horos_maxMovieIndex) {
                for case let file as NSManagedObject in horos_fileList(at: x) ?? NSMutableArray() {
                    (browser.database as? RemoteDicomDatabase)?.object(file, setValue: value, forKey: "isKeyImage")
                }
            }
        }

        willChangeValue(forKey: "KeyImageCounter")
        didChangeValue(forKey: "KeyImageCounter")

        buildMatrixPreview(false)
        horos_imageView?.needsDisplay = true
        saveDatabase()

        adjustKeyImage()
    }
}
