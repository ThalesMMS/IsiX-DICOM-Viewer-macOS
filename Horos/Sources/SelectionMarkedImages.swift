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
import IsiXPreferences

// The images of the database window's selection that carry ROIs or are key
// images, which the "ROIs & Keys" toolbar item, the Open Special menu and the
// export of ROI and key images ask for, and the viewer that opens them.
// BrowserController keeps the selectors the toolbar, the menus and the
// former plugins send, and hands their work here. The answers are kept until
// the selection changes, in the browser's selection cache, which the database
// switch clears.

/// The presentation of an image's series, read before the viewer opens: the
/// viewer gathers images of several series, and each image keeps the window,
/// the orientation and the zoom of the series it came from.
@MainActor private struct SeriesPresentation {
    let image: DicomImage
    let windowWidth: NSNumber?
    let windowLevel: NSNumber?
    let rotationAngle: NSNumber?
    let yFlipped: NSNumber?
    let xFlipped: NSNumber?
    let xOffset: NSNumber?
    let yOffset: NSNumber?
    let displayStyle: NSNumber?
    let scale: NSNumber?

    init(of image: DicomImage) {
        let series: DicomSeries? = image.series
        self.image = image
        windowWidth = series?.windowWidth
        windowLevel = series?.windowLevel
        rotationAngle = series?.rotationAngle
        yFlipped = series?.yFlipped
        xFlipped = series?.xFlipped
        xOffset = series?.xOffset
        yOffset = series?.yOffset
        displayStyle = series?.displayStyle
        scale = series?.scale
    }
}

@MainActor final class SelectionMarkedImages {

    private let browser: BrowserController
    private let processGraph: ProcessGraph
    private let preferences: any PreferenceStore

    init(browser: BrowserController, processGraph: ProcessGraph, preferences: any PreferenceStore) {
        self.browser = browser
        self.processGraph = processGraph
        self.preferences = preferences
    }

    /// The answers kept for the last selection.
    private var cache: BrowserSelectionCache {
        browser.selectionCache
    }

    /// The images of the selection: the thumbnails' when the menu item is in
    /// their menu or they have the focus, the list's otherwise.
    private func selectedImages(for sender: Any?) -> [NSObject] {
        let selection = NSMutableArray()
        if browser.isThumbnailMenuItem(sender) || browser.window?.firstResponder === browser.horos_oMatrix {
            _ = browser.files(forDatabaseMatrixSelection: selection)
        } else {
            _ = browser.files(forDatabaseOutlineSelection: selection)
        }
        return selection.compactMap { $0 as? NSObject }
    }

    /// Whether every image is of the series of the last one.
    private static func sameSeries(_ images: [DicomImage]) -> Bool {
        let series = images.last?.series
        return images.allSatisfy { $0.series === series }
    }

    // MARK: - The images

    /// The images of the selection that have ROIs or are key images, and
    /// whether they are of one series.
    func roisAndKeyImages(_ sender: Any?) -> (images: [DicomImage], sameSeries: Bool) {
        let selection = selectedImages(for: sender)

        if let images = cache.ROIsAndKeyImagesCache, cache.lastROIsAndKeyImagesSelectedFiles == selection {
            return (images, cache.ROIsAndKeyImagesCacheSameSeries)
        }

        var images: [DicomImage] = []
        if !selection.isEmpty {
            var study: DicomStudy? = nil
            var studyROIs: [Any]? = nil

            for case let image as DicomImage in selection {
                if study !== image.series?.study {
                    study = image.series?.study
                    studyROIs = (study?.roiSRSeries()?.images as NSSet?)?.allObjects
                }

                if let exception = HorosObjCException.caught({
                    // The scale of an ROI image holds the number of its ROIs.
                    if let roiImage = study?.roiForImage(image, inArray: studyROIs.map { $0 as NSArray }),
                       roiImage.scale == nil || roiImage.scale.int32Value > 0 {
                        images.append(image)
                    } else if image.isKeyImage()?.boolValue == true {
                        images.append(image)
                    }
                }) {
                    BrowserObjC.log(exception, stack: true, "-[BrowserController ROIsAndKeyImages:sameSeries:]")
                }
            }
            cache.ROIsAndKeyImagesCacheSameSeries = Self.sameSeries(images)
        }

        cache.ROIsAndKeyImagesCache = images
        cache.lastROIsAndKeyImagesSelectedFiles = selection
        return (images, cache.ROIsAndKeyImagesCacheSameSeries)
    }

    /// The images of the selection that have ROIs, and whether they are of
    /// one series.
    func roiImages(_ sender: Any?) -> (images: [DicomImage], sameSeries: Bool) {
        let selection = selectedImages(for: sender)

        if let images = cache.ROIsImagesCache, cache.lastROIsImagesSelectedFiles == selection {
            return (images, cache.ROIsImagesCacheSameSeries)
        }

        var images: [DicomImage] = []
        if !selection.isEmpty {
            for case let image as DicomImage in selection {
                let path = image.series?.study?.roiPath(forImage: image)

                if let exception = HorosObjCException.caught({
                    // An unreadable ROI SR has no data: NSUnarchiver dies on nil, and
                    // no @catch saves the app from that.
                    let data = path != nil ? SRAnnotation.roi(fromDICOM: path) : nil
                    if (RestrictedUnarchiver.unarchiveROIs(with: data)?.count ?? 0) > 0 {
                        images.append(image)
                    }
                }) {
                    BrowserObjC.log(exception, "-[BrowserController ROIImages:sameSeries:]")
                }
            }
            cache.ROIsImagesCacheSameSeries = Self.sameSeries(images)
        }

        cache.ROIsImagesCache = images
        cache.lastROIsImagesSelectedFiles = selection
        return (images, cache.ROIsImagesCacheSameSeries)
    }

    /// The key images of the selection.
    func keyImages(_ sender: Any?) -> [DicomImage] {
        let selection = selectedImages(for: sender)

        if let images = cache.KeyImagesCache, cache.lastKeyImagesSelectedFiles == selection {
            return images
        }

        let images = selection.compactMap { $0 as? DicomImage }.filter { $0.isKeyImage()?.boolValue == true }
        cache.KeyImagesCache = images
        cache.lastKeyImagesSelectedFiles = selection
        return images
    }

    // MARK: - Opening them

    /// Opens the images with ROIs and the key images of the selection in one
    /// viewer; images of several series keep their series' presentation.
    /// With Escape held, they are exported at once and the viewer closed.
    func openInViewer(_ sender: Any?) {
        let (images, sameSeries) = roisAndKeyImages(sender)

        guard !images.isEmpty else {
            HorosAlertPanel.runInformational(title: NSLocalizedString("ROIs Images", comment: ""),
                                             message: NSLocalizedString("No images containing ROIs or Key Images are found in this selection.", comment: ""),
                                             defaultButton: NSLocalizedString("OK", comment: ""),
                                             alternateButton: nil,
                                             otherButton: nil)
            return
        }

        let presentations = sameSeries ? [] : images.map(SeriesPresentation.init(of:))

        BrowserController.horos_dontShowOpenSubSeries = true
        let viewer = browser.viewerOpener.openViewer([images], movie: false, viewer: nil, keyImagesOnly: false)
        BrowserController.horos_dontShowOpenSubSeries = false

        if !sameSeries {
            viewer?.imageView()?.copysettingsinseries = false

            for presentation in presentations {
                let image = presentation.image

                // Each setting is copied when the source series has one to
                // copy, not when the destination image already carries one:
                // an image with no presentation of its own would otherwise
                // revert to its defaults.
                if let value = presentation.windowWidth { image.windowWidth = value }
                if let value = presentation.windowLevel { image.windowLevel = value }
                if let value = presentation.rotationAngle { image.rotationAngle = value }
                if let value = presentation.yFlipped { image.yFlipped = value }
                if let value = presentation.xFlipped { image.xFlipped = value }
                if let value = presentation.xOffset { image.xOffset = value }
                if let value = presentation.yOffset { image.yOffset = value }

                let displayStyle = presentation.displayStyle?.int32Value ?? 0
                let seriesScale = image.series?.scale?.floatValue ?? 0
                let imageViewFrame = viewer?.imageView()?.frame ?? .zero
                if displayStyle == 3 {
                    image.scale = NSNumber(value: Float(Double(seriesScale) * sqrt(Double(imageViewFrame.size.height * imageViewFrame.size.width))))
                } else if displayStyle == 2 {
                    image.scale = NSNumber(value: Float(Double(seriesScale) * Double(imageViewFrame.size.width)))
                } else if let value = presentation.scale {
                    image.scale = value
                }
            }
        }

        if preferences[ViewerPreferences.autoTiling] {
            NSApp.sendAction(#selector(BrowserController.tileWindows(_:)), to: nil, from: browser)
        } else if let appController = processGraph.appController, !appController.checkAllWindowsAreVisibleIsOff {
            processGraph.windowArranger.bringViewersToFront(makeKey: true)
        }

        // Escape held: the images are exported, and the viewer closed.
        if CGEventSource.keyState(.combinedSessionState, key: 53),
           let viewer = ViewerController.getDisplayed2DViewers()?.firstObject as? ViewerController {
            viewer.exportAllImages("Key And ROIs images")
            viewer.window?.close()
        }
    }
}
