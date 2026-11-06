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
// images. Where the buttons land and the state of the controls are
// IsiXImaging's KeyImageNavigation; ViewerKeyImages applies them to the viewer
// and reaches the database window through KeyImageBrowsing, taken from the
// viewer's graph. The viewer keeps the selectors of the former Objective-C
// methods as a façade.

/// What the key images ask of the database window: the shared database of a
/// file, saving the databases of the files marked, the series of a study or
/// the images of a series, and opening a series or images in a viewer.
@MainActor protocol KeyImageBrowsing {
    /// The shared database of another computer `file` is a row of, which the
    /// browser may not show; nil for a database of this computer.
    func remoteDatabase(of file: NSManagedObject?) -> RemoteDicomDatabase?
    /// Saves the database of each of `files`, once each.
    func saveDatabases(of files: [NSManagedObject])
    /// The children of a study (its series) or of a series (its images), in
    /// the browser's order.
    func children(of item: Any?) -> [Any]?
    /// Opens `series` in `viewer`.
    func load(_ series: NSManagedObject?, into viewer: ViewerController, keyImagesOnly: Bool)
    /// Opens `images` in `viewer`, as one series.
    func open(_ images: [Any], in viewer: ViewerController, keyImagesOnly: Bool)
}

/// The browser of the process graph, asked at each call, as the key images'
/// database window.
@MainActor struct BrowserKeyImages: KeyImageBrowsing {
    let processGraph: ProcessGraph

    private var browser: BrowserController? {
        processGraph.currentBrowser
    }

    /// The file's own database, not the one the browser shows: a change of
    /// mark the server is not told of is undone at the next update of the index.
    func remoteDatabase(of file: NSManagedObject?) -> RemoteDicomDatabase? {
        RemoteDicomDatabase.database(of: file)
    }

    /// The files' own databases, not the one the browser shows: a viewer of
    /// a study of another database keeps its marks unsaved otherwise, until
    /// some other save of that database.
    func saveDatabases(of files: [NSManagedObject]) {
        var saved = Set<ObjectIdentifier>()
        for file in files {
            guard let database = (file.managedObjectContext as? N2ManagedObjectContext)?.database,
                  saved.insert(ObjectIdentifier(database)).inserted else { continue }
            _ = database.save(nil)
        }
    }

    func children(of item: Any?) -> [Any]? {
        browser?.childrenArray(item)
    }

    func load(_ series: NSManagedObject?, into viewer: ViewerController, keyImagesOnly: Bool) {
        _ = browser?.loadSeries(series, viewer, true, keyImagesOnly: keyImagesOnly)
    }

    func open(_ images: [Any], in viewer: ViewerController, keyImagesOnly: Bool) {
        _ = browser?.openViewer(fromImages: [images], movie: false, viewer: viewer, keyImagesOnly: keyImagesOnly)
    }
}

/// The key image actions of one 2D viewer, made for one call over its graph.
@MainActor struct ViewerKeyImages {
    /// Held strongly for the length of a call: the viewer's teardown, which
    /// its deinit runs, may move through its images, and forming an unowned or
    /// weak reference to an object being deallocated traps.
    let viewer: ViewerController
    let browser: any KeyImageBrowsing

    /// The key of the mark of a file, which the files the viewer shows answer
    /// by key whatever their class (a plugin's viewer may hold its own).
    private static let keyImageKey = "isKeyImage"

    /// The file `index` of frame `movie`.
    private func file(_ index: Int, movie: Int) -> NSManagedObject? {
        viewer.horos_fileList(at: movie)?.object(at: index) as? NSManagedObject
    }

    /// The file of the image shown.
    private var shownFile: NSManagedObject? {
        file(Int(viewer.horos_imageView?.curImage ?? 0), movie: Int(viewer.horos_curMovieIndex))
    }

    /// Whether `file` is marked as a key image.
    private static func isMarked(_ file: AnyObject?) -> Bool {
        (file?.value(forKey: keyImageKey) as? NSNumber)?.boolValue ?? false
    }

    /// Marks `file` as a key image, or not.
    private static func setMark(_ flag: NSNumber, of file: NSManagedObject?) {
        file?.setValue(flag, forKey: keyImageKey)
    }

    /// Whether file `index` of the frame shown is marked as a key image.
    func isKeyImageFile(_ index: Int) -> Bool {
        Self.isMarked(viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.object(at: index) as AnyObject?)
    }

    /// The check box: marks the image shown as its state says.
    func checkBoxChanged(_ sender: Any?) {
        guard !viewer.horos_postprocessed else { return }

        let flag = NSNumber(value: Self.objcBool(ViewerSender.state(sender)))
        let file = shownFile
        Self.setMark(flag, of: file)
        browser.remoteDatabase(of: file)?.object(file, setValue: flag, forKey: Self.keyImageKey)

        viewer.willChangeValue(forKey: "KeyImageCounter")
        viewer.didChangeValue(forKey: "KeyImageCounter")

        viewer.buildMatrixPreview(false)

        viewer.horos_imageView?.needsDisplay = true

        browser.saveDatabases(of: file.map { [$0] } ?? [])
    }

    /// The "next" (tag 0) and "previous" key image buttons: the next key
    /// image of the series shown, or else the first one of the next series of
    /// the study that has key images (beeping when there is none).
    func findNextPrevious(_ sender: Any?) {
        if viewer.horos_postprocessed {
            alertPostProcessed()
            return
        }

        viewer.checkEverythingLoaded()

        let isPrevious = Self.objcBool(ViewerSender.tag(sender))
        let movie = Int(viewer.horos_curMovieIndex)
        if let index = KeyImageNavigation.nextInSeries(from: Int(viewer.horos_imageView?.curImage ?? 0), count: viewer.horos_fileList(at: movie)?.count ?? 0,
                                                       isPrevious: isPrevious, flipped: viewer.horos_imageView?.flippedData ?? false,
                                                       isKey: isKeyImageFile) {
            show(keyImage: index)
            return
        }

        // Nothing found: the next (or previous) series of the study.
        let seriesObject = viewer.horos_imageView?.seriesObj()
        let seriesArray = browser.children(of: seriesObject?.value(forKey: "study")) ?? []
        let nextSeries = !isPrevious
        let position = seriesArray.firstIndex { ($0 as AnyObject) === seriesObject }
        for i in KeyImageNavigation.seriesToSearch(from: position, count: seriesArray.count, nextSeries: nextSeries) {
            let candidate = seriesArray[i]
            if ((candidate as? DicomSeries)?.keyImages()?.count ?? 0) > 0 {
                browser.load(candidate as? NSManagedObject, into: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)

                viewer.showCurrentThumbnail(viewer)
                viewer.updateNavigator()

                let count = viewer.horos_fileList(at: Int(viewer.horos_curMovieIndex))?.count ?? 0
                if let index = KeyImageNavigation.landing(count: count, nextSeries: nextSeries, flipped: viewer.horos_imageView?.flippedData ?? false,
                                                          isKey: isKeyImageFile) {
                    show(keyImage: index)
                    return
                }
            }
        }

        NSSound.beep()
    }

    /// The "all images" / "key images only" popup: reopens the series with
    /// all its images, or only with its key images (an alert, and back to all
    /// images, when it has none).
    func displayButtonChanged() {
        if viewer.horos_postprocessed {
            alertPostProcessed()
            return
        }

        let series = shownFile?.value(forKey: "series")

        viewer.checkEverythingLoaded()

        viewer.horos_displayOnlyKeyImages = Self.objcBool(viewer.horos_keyImagePopUpButton?.indexOfSelectedItem ?? 0)
        guard let series else { return }

        let images = browser.children(of: series) ?? []
        if !viewer.horos_displayOnlyKeyImages {
            browser.open(images, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
        } else {
            let keyImages = images.filter { Self.isMarked($0 as AnyObject) }

            if keyImages.isEmpty {
                HorosAlertPanel.run(title: NSLocalizedString("Key Images", comment: ""),
                                    message: NSLocalizedString("No key images have been selected in this series.", comment: ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
                viewer.horos_keyImagePopUpButton?.selectItem(at: 0)
            } else {
                browser.open(keyImages, in: viewer, keyImagesOnly: viewer.horos_displayOnlyKeyImages)
            }
        }
    }

    /// Marks as key images the images that have ROIs, in every frame.
    func markImagesWithROIs() {
        if viewer.horos_postprocessed {
            alertPostProcessed()
            return
        }

        let yes = NSNumber(value: true)
        let files = filesWithROIs()
        for file in files {
            Self.setMark(yes, of: file)
        }

        for file in files {
            browser.remoteDatabase(of: file)?.object(file, setValue: yes, forKey: Self.keyImageKey)
        }

        viewer.buildMatrixPreview(false)
        viewer.horos_imageView?.needsDisplay = true
        browser.saveDatabases(of: files)

        adjustControls()
    }

    /// The key image shortcut: toggles the check box and applies it.
    func toggle() {
        if viewer.horos_postprocessed {
            alertPostProcessed()
            return
        }

        guard let check = viewer.keyImageCheck else {
            checkBoxChanged(nil)
            return
        }
        check.state = KeyImageNavigation.toggled(isChecked: check.state.rawValue != 0) ? .on : .off
        checkBoxChanged(check)
    }

    /// The check box and the popup for the image shown.
    func adjustControls() {
        let controls = KeyImageNavigation.controls(postprocessed: viewer.horos_postprocessed, current: Int(viewer.horos_imageView?.curImage ?? 0),
                                                   isKey: isKeyImageFile)
        viewer.keyImageCheck?.isEnabled = controls.isEnabled
        viewer.horos_keyImagePopUpButton?.isEnabled = controls.isEnabled
        if let checked = controls.isChecked {
            viewer.keyImageCheck?.state = checked ? .on : .off
        }
    }

    /// Marks or unmarks every image of every frame, then refreshes the
    /// thumbnails, the view, the database and the check box.
    func markEveryImage(asKeyImage key: Bool) {
        if viewer.horos_postprocessed {
            alertPostProcessed()
            return
        }

        let value = NSNumber(value: key)
        let files = everyFile()
        for file in files {
            Self.setMark(value, of: file)
        }

        for file in files {
            browser.remoteDatabase(of: file)?.object(file, setValue: value, forKey: Self.keyImageKey)
        }

        viewer.willChangeValue(forKey: "KeyImageCounter")
        viewer.didChangeValue(forKey: "KeyImageCounter")

        viewer.buildMatrixPreview(false)
        viewer.horos_imageView?.needsDisplay = true
        browser.saveDatabases(of: files)

        adjustControls()
    }

    /// A value read as Objective-C's BOOL reads it: any non-zero value on
    /// arm64, the low byte on x86_64.
    static func objcBool(_ value: Int) -> Bool {
        #if arch(x86_64)
        return Int8(truncatingIfNeeded: value) != 0
        #else
        return value != 0
        #endif
    }

    /// Shows image `index` of the series and synchronizes the other viewers.
    private func show(keyImage index: Int) {
        viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: index))
        viewer.horos_imageView?.sendSyncMessage(0)
        viewer.adjustSlider()
        viewer.horos_imageView?.displayIfNeeded()
    }

    private func alertPostProcessed() {
        HorosAlertPanel.run(title: NSLocalizedString("Key Images", comment: ""),
                            message: NSLocalizedString("This dataset has been post processed (reslicing, MPR, ...). You cannot create/modify/search key images. Revert to the original series or create a secondary capture series to do this.", comment: ""),
                            defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
    }

    /// Every file of every frame, in order.
    private func everyFile() -> [NSManagedObject] {
        (0..<Int(viewer.horos_maxMovieIndex)).flatMap { x in
            (viewer.horos_fileList(at: x) ?? []).compactMap { $0 as? NSManagedObject }
        }
    }

    /// The files whose image has ROIs, in every frame.
    private func filesWithROIs() -> [NSManagedObject] {
        var files: [NSManagedObject] = []
        for x in 0..<Int(viewer.horos_maxMovieIndex) {
            guard let list = viewer.horos_fileList(at: x) else { continue }
            for i in 0..<list.count {
                if let file = list.object(at: i) as? NSManagedObject, ((viewer.horos_roiList(at: x)?.object(at: i) as? [Any])?.count ?? 0) > 0 {
                    files.append(file)
                }
            }
        }
        return files
    }
}

extension ViewerController {

    /// The key image actions of the viewer, over its graph.
    var keyImageActions: ViewerKeyImages {
        ViewerKeyImages(viewer: self, browser: BrowserKeyImages(processGraph: sessionGraph.processGraph))
    }
}

public extension ViewerController {

    /// The key image check box: marks the image shown as its state says.
    @objc(keyImageCheckBox:)
    func keyImageCheckBox(_ sender: Any!) {
        keyImageActions.checkBoxChanged(sender)
    }

    /// The "next" (tag 0) and "previous" key image buttons.
    @objc(findNextPreviousKeyImage:)
    func findNextPreviousKeyImage(_ sender: Any!) {
        keyImageActions.findNextPrevious(sender)
    }

    /// The "all images" / "key images only" popup.
    @objc(keyImageDisplayButton:)
    func keyImageDisplayButton(_ sender: Any!) {
        keyImageActions.displayButtonChanged()
    }

    /// Marks as key images the images that have ROIs, in every frame.
    @objc(setROIsImagesKeyImages:)
    func setROIsImagesKeyImages(_ sender: Any!) {
        keyImageActions.markImagesWithROIs()
    }

    /// Unmarks every image of every frame.
    @objc(setAllNonKeyImages:)
    func setAllNonKeyImages(_ sender: Any!) {
        keyImageActions.markEveryImage(asKeyImage: false)
    }

    /// Marks every image of every frame.
    @objc(setAllKeyImages:)
    func setAllKeyImages(_ sender: Any!) {
        keyImageActions.markEveryImage(asKeyImage: true)
    }

    /// The key image shortcut: toggles the check box and applies it.
    @objc(setKeyImage:)
    func setKeyImage(_ sender: Any!) {
        keyImageActions.toggle()
    }

    /// The check box and the popup: disabled for a post processed series,
    /// otherwise enabled, the box showing whether the image shown is a key
    /// image.
    @objc(adjustKeyImage)
    func adjustKeyImage() {
        keyImageActions.adjustControls()
    }

    /// Whether image `index` of the frame shown is a key image (never in a
    /// post processed series).
    @objc(isKeyImage:)
    func isKeyImage(_ index: Int32) -> Bool {
        if horos_postprocessed { return false }
        return keyImageActions.isKeyImageFile(Int(index))
    }

    @objc(displayOnlyKeyImages)
    func displayOnlyKeyImages() -> Bool {
        horos_displayOnlyKeyImages
    }
}
