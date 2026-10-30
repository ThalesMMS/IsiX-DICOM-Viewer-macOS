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
import IsiXImaging

// Opening lists of database images in viewers, apart from the browser
// window: the key images of the lists, the memory check (with thinning when
// it does not fit), the pre-flip of series stored head first, reading the
// images, and a 2D viewer per list or one 4D viewer for all of them. The
// browser's -openViewerFromImages:… sends here; the rules are in
// IsiXImaging (ViewerOpeningRules.swift).

/// `[[ViewerController alloc] initWithPix: f withFiles: d withVolume: v]`,
/// given the volume itself (Swift would pass the NSData parameter a copy).
/// The viewer keeps the reference of the allocation, as the former code
/// left it: it is released when its window closes.
@MainActor func allocateViewer(_ f: NSMutableArray, _ d: NSMutableArray, _ v: NSData?) -> ViewerController? {
    typealias Initializer = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Unmanaged<AnyObject>?
    let selector = NSSelectorFromString("initWithPix:withFiles:withVolume:")
    guard let implementation = class_getMethodImplementation(ViewerController.self, selector),
          let allocated = (ViewerController.self as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue() else { return nil }
    let made = unsafeBitCast(implementation, to: Initializer.self)(allocated, selector, f, d, v)
    return made?.takeUnretainedValue() as? ViewerController
}

/// `[viewer changeImageData: f :d :v :b]`, with the NSData object itself.
@MainActor func changeViewerImageData(_ viewer: ViewerController, _ f: NSMutableArray, _ d: NSMutableArray, _ v: NSData?, _ b: Bool) {
    typealias Send = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?, ObjCBool) -> Void
    let selector = NSSelectorFromString("changeImageData::::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f, d, v, ObjCBool(b))
}

/// `[viewer addMovieSerie: f :d :v]`, with the NSData object itself.
@MainActor func addViewerMovieSeries(_ viewer: ViewerController, _ f: NSMutableArray, _ d: NSMutableArray, _ v: NSData?) {
    typealias Send = @convention(c) (AnyObject, Selector, NSMutableArray?, NSMutableArray?, NSData?) -> Void
    let selector = NSSelectorFromString("addMovieSerie:::")
    unsafeBitCast(viewer.method(for: selector), to: Send.self)(viewer, selector, f, d, v)
}

/// What memory reads of a database image.
nonisolated func memoryImage(_ image: Any?) -> MemoryImage {
    let object = image as AnyObject?
    func value(_ key: String) -> Int64 { (object?.value(forKey: key) as? NSNumber)?.int64Value ?? 0 }
    return MemoryImage(width: value("width"), height: value("height"), frames: value("numberOfFrames"), series: value("numberOfSeries"))
}

@MainActor
final class ViewerSeriesLoader {

    private unowned let browser: BrowserController

    init(browser: BrowserController) {
        self.browser = browser
    }

    /// -computeEnoughMemory:: — whether the lists fit, with a probe of each
    /// held at once, and the megabytes they need.
    nonisolated static func enoughMemory(for lists: [[Any]], requiredMegabytes: UnsafeMutablePointer<UInt>?) -> Bool {
        requiredMegabytes?.pointee = 0
        if lists.isEmpty { return true }
        let thread = Thread.current
        var probes: [UnsafeMutableRawPointer] = []
        var counting = 0, inOperation = false
        var start = Date.timeIntervalSinceReferenceDate
        var result: (enough: Bool, requiredMegabytes: UInt) = (false, 0)
        // An image that cannot be read raises: the probes are freed and the
        // operation left before the exception goes on, as @finally did.
        let exception = BrowserObjC.attempt {
            result = ViewerMemory.enoughMemory(
                imageCounts: lists.map(\.count), image: { memoryImage(lists[$0][$1]) },
                allocate: { bytes in
                    guard let probe = malloc(Int(bytes)) else { return false }
                    probes.append(probe)
                    return true
                },
                willCount: { count in
                    counting = count
                    thread.enterOperation()
                    inOperation = true
                    thread.status = NSLocalizedString("Evaluating amount of memory needed...", comment: "")
                    start = Date.timeIntervalSinceReferenceDate
                },
                counted: { index in
                    if Date.timeIntervalSinceReferenceDate - start > 0.5 || index == counting - 1 {
                        thread.progress = Double(index + 1) / Double(counting)
                        start = Date.timeIntervalSinceReferenceDate
                    }
                },
                didCount: {
                    inOperation = false
                    thread.exitOperation()
                })
        }
        probes.forEach { free($0) }
        if inOperation { thread.exitOperation() }
        if let exception { exception.raise() }
        requiredMegabytes?.pointee = result.requiredMegabytes
        return result.enough
    }

    /// -openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:.
    func open(_ toOpenArray: [[Any]], movie movieViewer: Bool, viewer: ViewerController?, keyImagesOnly keyImages: Bool,
              tryToFlipData: Bool) -> ViewerController? {
        if toOpenArray.isEmpty { return nil }
        var toOpenArray = toOpenArray
        let defaults = UserDefaults.standard
        let savedAUTOHIDEMATRIX = defaults.bool(forKey: "AUTOHIDEMATRIX")

        var multiFrame = false, preFlippedData = false
        var movieController: ViewerController?
        var createdViewer = viewer
        let previousStudy = viewer?.currentStudy()
        var blocks: [UInt] = []
        var stop = false

        var wait: ThreadModalForWindowController?
        Thread.current.enterOperation()
        if browser.database?.hasPotentiallySlowDataAccess ?? false {
            Thread.current.name = NSLocalizedString("Loading series data...", comment: "")
            Thread.current.status = NSLocalizedString("Evaluating amount of memory needed...", comment: "")
            wait = ThreadModalForWindowController(thread: Thread.current, window: nil)
        }

        let exception = BrowserObjC.attempt {
            //  (1) keyImages
            if keyImages {
                var keyImagesToOpenArray: [[Any]] = []
                if let exception = BrowserObjC.attempt({
                    for loadList in toOpenArray {
                        let keyImagesArray = loadList.filter { (($0 as? DicomImage)?.value(forKey: "isKeyImage") as? NSNumber)?.boolValue == true }
                        if !keyImagesArray.isEmpty { keyImagesToOpenArray.append(keyImagesArray) }
                    }
                }) {
                    BrowserObjC.log(exception, "-[BrowserController openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:]")
                }
                if !keyImagesToOpenArray.isEmpty {
                    toOpenArray = keyImagesToOpenArray
                } else if HorosAlertPanel.runInformational(title: NSLocalizedString("Key Images", comment: ""),
                                                           message: NSLocalizedString("No key images in these images.", comment: ""),
                                                           defaultButton: NSLocalizedString("All Images", comment: ""),
                                                           alternateButton: NSLocalizedString("Cancel", comment: ""),
                                                           otherButton: nil) == HorosAlertPanel.alternateResponse {
                    stop = true
                    return
                }
            }

            defaults.set(false, forKey: "AUTOHIDEMATRIX")

            if !BrowserController.horos_dontShowOpenSubSeries {
                if (NSApplication.shared.currentEvent?.modifierFlags.contains(.option) ?? false)
                    || !ViewerSeriesLoader.enoughMemory(for: toOpenArray, requiredMegabytes: nil) || browser.horos_openSubSeriesFlag {
                    guard let subSeries = browser.openSubSeries(toOpenArray as [Any]) as? [[Any]] else {
                        stop = true
                        return
                    }
                    toOpenArray = subSeries
                }
            }

            for list in toOpenArray where !list.isEmpty && !(list.last is DicomImage) {
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Loading", comment: ""),
                                                     message: NSLocalizedString("Failed to load the series.", comment: ""),
                                                     defaultButton: NSLocalizedString("All Images", comment: ""),
                                                     alternateButton: NSLocalizedString("OK", comment: ""), otherButton: nil)
                stop = true
                return
            }

            //  (2) Compute Required Memory
            let lists = toOpenArray
            var retrying = false
            // The blocks of a pass are held together, as the volumes will be.
            var probes: [UnsafeMutableRawPointer] = []
            var planned: Result<ViewerMemoryPlan, ViewerMemoryFailure> = .failure(.notEnoughMemory)
            let planException = BrowserObjC.attempt { planned = ViewerMemory.plan(
                imageCounts: lists.map(\.count), image: { memoryImage(lists[$0][$1]) },
                visit: { list in
                    let first = lists[list].first as AnyObject?
                    first?.setValue(Date(), forKeyPath: "series.dateOpened")
                    first?.setValue(Date(), forKeyPath: "series.study.dateOpened")
                },
                allocate: { block in
                    defer { retrying = false }
                    guard let probe = malloc(Int(block) * MemoryLayout<Float>.size + 4096) else {
                        if retrying { NSLog("Failed to allocate memory for: %lu Mb", (block * UInt(MemoryLayout<Float>.size)) / (1024 * 1024)) }
                        return false
                    }
                    probes.append(probe)
                    return true
                },
                purge: {
                    // Try to find the memory...
                    self.freeMemoryForOpening()
                    retrying = true
                },
                passEnded: {
                    probes.forEach { free($0) }
                    probes.removeAll()
                }) }
            probes.forEach { free($0) }
            if let planException { planException.raise() }
            let plan = planned
            let memory: ViewerMemoryPlan
            switch plan {
            case .success(let planned):
                memory = planned
            case .failure(.unsafeDimensions):
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Opening Error", comment: ""),
                                                     message: NSLocalizedString("The selected image dimensions cannot be loaded safely.", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                stop = true
                return
            case .failure(.notEnoughMemory):
                _ = HorosAlertPanel.runInformational(title: NSLocalizedString("Memory", comment: ""),
                                                     message: NSLocalizedString("Not enough memory to open the selected images.", comment: ""),
                                                     defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                stop = true
                return
            }
            if memory.subSampling != 1 { NSLog("Test memory failed -> sub-sampling") }
            toOpenArray = zip(memory.listIndices, memory.imageIndices).map { list, images in images.map { lists[list][$0] } }
            blocks = memory.blocks
            multiFrame = memory.multiFrame

            var result = HorosAlertPanel.defaultResponse
            if memory.subSampling != 1 {
                for window in NSApp.windows where window.isMiniaturized {
                    window.deminiaturize(self)
                }
                result = HorosAlertPanel.runInformational(title: NSLocalizedString("Memory", comment: ""),
                                                          message: String(format: NSLocalizedString("There is not enough memory to load all selected images. Load a subset containing 1 in every %ld images?", comment: ""), memory.subSampling),
                                                          defaultButton: NSLocalizedString("OK", comment: ""),
                                                          alternateButton: NSLocalizedString("Cancel", comment: ""), otherButton: nil)
            }

            //  (3) Load Images (memory allocation)
            var notEnoughMemory = false
            if result == HorosAlertPanel.defaultResponse {
                if movieViewer {
                    NSLog("4D Viewer TOTAL: %lu Mb", (memory.total * UInt(MemoryLayout<Float>.size)) / (1024 * 1024))
                    var tests: [UnsafeMutableRawPointer?] = []
                    for block in blocks {
                        let test = malloc(Int(block) * MemoryLayout<Float>.size)
                        NSLog("4D Viewer: I will try to allocate: %lu Mb", (block * UInt(MemoryLayout<Float>.size)) / (1024 * 1024))
                        if test == nil { notEnoughMemory = true }
                        tests.append(test)
                    }
                    tests.forEach { free($0) }
                    if notEnoughMemory {
                        _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Memory", comment: ""),
                                                        message: NSLocalizedString("Not enough memory to open the selected images.", comment: ""),
                                                        defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
                    }
                }
            } else {
                notEnoughMemory = true
            }

            //  (4) Load Images loop
            if !notEnoughMemory {
                // Pre-flip data?
                var resortedToOpenArray: [[Any]] = []
                var isFlippedData: [Bool] = []
                for list in toOpenArray {
                    var list = list
                    var flipped = false
                    if !multiFrame && tryToFlipData && list.count > 2 {
                        if let exception = BrowserObjC.attempt({
                            let p1 = self.singleImagePix(list[1])
                            let p2 = self.singleImagePix(list[2])
                            if let p1, let p2, ViewerController.computeInterval(for: p1, and: p2) < 0 {
                                // Inverse the array
                                list.reverse()
                                preFlippedData = true
                                flipped = true
                            }
                        }) {
                            BrowserObjC.log(exception, stack: true, "-[BrowserController openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:]")
                        }
                    }
                    resortedToOpenArray.append(list)
                    isFlippedData.append(flipped)
                }
                if preFlippedData { toOpenArray = resortedToOpenArray }

                for (x, loadList) in toOpenArray.enumerated() {
                    let block = x < blocks.count ? blocks[x] : 0
                    guard let volume = malloc(Int(block) * MemoryLayout<Float>.size)?.assumingMemoryBound(to: Float.self) else { continue }
                    let volumeData = NSData(bytesNoCopy: volume, length: Int(block) * MemoryLayout<Float>.size, freeWhenDone: true)
                    multiFrame = self.load(loadList, into: volume, volumeData: volumeData, multiFrame: multiFrame, movie: movieViewer,
                                           viewer: viewer, flipped: isFlippedData[x], created: &createdViewer, movieController: &movieController)
                }
            }

            //  (5) movieController activation
            if let movieController {
                NSLog("openViewerFromImages-movieController activation")
                movieController.showWindowTransition()
                movieController.startLoadImageThread()
            }
        }
        if let exception {
            BrowserObjC.log(exception, stack: true, "-[BrowserController openViewerFromImages:movie:viewer:keyImagesOnly:tryToFlipData:]")
            _ = HorosAlertPanel.run(title: NSLocalizedString("Opening Error", comment: ""),
                                    message: String(format: NSLocalizedString("Opening Error : %@\r\r%@", comment: ""), exception, exception.printStackTrace() ?? ""),
                                    defaultButton: nil, alternateButton: nil, otherButton: nil)
        }
        defaults.set(savedAUTOHIDEMATRIX, forKey: "AUTOHIDEMATRIX")
        wait?.invalidate()
        Thread.current.exitOperation()
        if stop { return nil }

        if let movieController { createdViewer = movieController }

        browser.database?.save() // To save 'dateOpened' field, and allow independentContext to see it

        if defaults.bool(forKey: "AUTOTILING"), let viewer, defaults.bool(forKey: "tileWindowsOrderByStudyDate"),
           !BrowserObjC.literallyEqual(previousStudy?.studyInstanceUID, viewer.currentStudy()?.studyInstanceUID) {
            // Keep current row/column
            let tiling = ViewerTiling.rowsAndColumns(defaults.string(forKey: "LastWindowsTilingRowsColumns"))
            let d = tiling.map { ["rows": NSNumber(value: $0.rows), "columns": NSNumber(value: $0.columns)] as NSDictionary }
            AppController.shared()?.tileWindows(d)
        }

        return createdViewer
    }

    /// The first image of a file, for the pre-flip test.
    private func singleImagePix(_ image: Any) -> DCMPix? {
        let o = image as AnyObject
        return DCMPix(path: o.value(forKey: "completePath") as? String, 0, 1, nil, Int(BrowserObjC.intValue(o.value(forKey: "frameID"))),
                      Int(BrowserObjC.intValue(o.value(forKeyPath: "series.id"))), isBonjour: !(browser.database?.isLocal() ?? false), imageObj: o as? NSManagedObject)
    }

    /// Makes room before trying an allocation again: the string textures and
    /// the 8-bit images of the preview.
    private func freeMemoryForOpening() {
        DCMView.purgeStringTextureCache()
        _ = BrowserObjC.attempt {
            BrowserObjC.synchronized(self.browser.horos_previewPixThumbnails) {
                for case let pix as DCMPix in self.browser.horos_previewPix ?? [] {
                    pix.kill8bitsImage()
                    pix.revert(false)
                }
            }
        }
    }

    /// Reads the images of one list into `volume` and shows them: in the
    /// viewer given or a new 2D viewer, or as a time of the 4D viewer.
    /// Returns whether the list was one multi-frame file (or an earlier was).
    private func load(_ loadList: [Any], into volume: UnsafeMutablePointer<Float>, volumeData: NSData, multiFrame: Bool, movie movieViewer: Bool,
                      viewer: ViewerController?, flipped: Bool, created createdViewer: inout ViewerController?,
                      movieController: inout ViewerController?) -> Bool {
        var multiFrame = multiFrame
        let isBonjour = !(browser.database?.isLocal() ?? false)
        var mem = 0

        if let first = loadList.first as AnyObject? {
            WindowLayoutManager.shared()?.setCurrentHangingProtocolForModality(first.value(forKeyPath: "series.study.modality") as? String,
                                                                               description: first.value(forKeyPath: "series.study.studyName") as? String)
        }

        // Why viewerPix[0] (fixed value) within the loop? Because it's not a 4D volume!
        let viewerPix = NSMutableArray()
        let correspondingObjects = NSMutableArray()
        var missingFileReason: String?

        if loadList.count == 1, let curFile = loadList[0] as AnyObject?, BrowserObjC.intValue(curFile.value(forKey: "numberOfFrames")) > 1 {
            multiFrame = true
            let frames = Int(BrowserObjC.intValue(curFile.value(forKey: "numberOfFrames")))
            for i in 0..<frames {
                if let dcmPix = DCMPix(path: curFile.value(forKey: "completePath") as? String, i, frames, volume + mem, i,
                                       Int(BrowserObjC.intValue(curFile.value(forKeyPath: "series.id"))), isBonjour: isBonjour,
                                       imageObj: curFile as? NSManagedObject) {
                    mem += Int(BrowserObjC.intValue(curFile.value(forKey: "width"))) * Int(BrowserObjC.intValue(curFile.value(forKey: "height")))
                    viewerPix.add(dcmPix)
                    correspondingObjects.add(curFile)
                }
            }
        } else {
            for (i, image) in loadList.enumerated() {
                let curFile = image as AnyObject
                if let dcmPix = DCMPix(path: curFile.value(forKey: "completePath") as? String, i, loadList.count, volume + mem,
                                       Int(BrowserObjC.intValue(curFile.value(forKey: "frameID"))),
                                       Int(BrowserObjC.intValue(curFile.value(forKeyPath: "series.id"))), isBonjour: isBonjour,
                                       imageObj: curFile as? NSManagedObject) {
                    mem += Int(BrowserObjC.intValue(curFile.value(forKey: "width"))) * Int(BrowserObjC.intValue(curFile.value(forKey: "height")))
                    viewerPix.add(dcmPix)
                    correspondingObjects.add(curFile)
                } else {
                    // Not just "not readable": a study imported as links to a
                    // disc says that when the disc is out, which reads as a
                    // damaged study rather than a disconnected one.
                    let reason = MissingFileReason.reason(forPath: curFile.value(forKey: "completePath") as? String,
                                                               inDatabaseFolder: (curFile.value(forKey: "inDatabaseFolder") as? NSNumber)?.boolValue ?? false)
                    NSLog("---- %@", reason)
                    if missingFileReason == nil { missingFileReason = reason }
                }
            }
        }

        if viewerPix.count != loadList.count && !multiFrame {
            for (i, pix) in viewerPix.enumerated() {
                (pix as? DCMPix)?.id = i
                (pix as? DCMPix)?.tot = viewerPix.count
            }
            if viewerPix.count == 0 {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Files not available (readable)", comment: ""),
                                                message: String(format: NSLocalizedString("No files available (readable) in this series.\r\r%@", comment: ""), missingFileReason ?? ""),
                                                defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: nil, otherButton: nil)
            } else {
                _ = HorosAlertPanel.runCritical(title: NSLocalizedString("Not all files available (readable)", comment: ""),
                                                message: String(format: NSLocalizedString("Not all files are available (readable) in this series.\r%@ are missing.\r\r%@", comment: ""),
                                                                BrowserObjC.singularPlural(loadList.count - viewerPix.count, NSLocalizedString("file", comment: ""), NSLocalizedString("files", comment: "")),
                                                                missingFileReason ?? ""),
                                                defaultButton: NSLocalizedString("Continue", comment: ""), alternateButton: nil, otherButton: nil)
            }
        }

        // Opening the images of viewerPix in the adequate viewer.
        DCMView.setDontListenToSyncMessage(true)
        let defaults = UserDefaults.standard
        let copyCOPYSETTINGS = defaults.bool(forKey: "COPYSETTINGS")
        defaults.set(false, forKey: "COPYSETTINGS")

        if viewerPix.count > 0 {
            if !movieViewer {
                if multiFrame {
                    let filesAr = NSMutableArray(capacity: viewerPix.count)
                    if correspondingObjects.count > 0 {
                        for _ in 0..<viewerPix.count { filesAr.add(correspondingObjects[0]) }
                    }
                    if let viewer {
                        // reuse of existing viewer
                        changeViewerImageData(viewer, viewerPix, filesAr, volumeData, false)
                        viewer.startLoadImageThread()
                    } else {
                        // creation of new viewer
                        createdViewer = allocateViewer(viewerPix, filesAr, volumeData)
                        createdViewer?.showWindowTransition()
                        createdViewer?.startLoadImageThread()
                    }
                } else {
                    if let viewer {
                        // reuse of existing viewer
                        changeViewerImageData(viewer, viewerPix, NSMutableArray(array: correspondingObjects), volumeData, false)
                        viewer.startLoadImageThread()
                        if flipped { viewer.flipDataSeries(browser) }
                    } else {
                        // creation of new viewer
                        createdViewer = allocateViewer(viewerPix, NSMutableArray(array: correspondingObjects), volumeData)
                        createdViewer?.showWindowTransition()
                        createdViewer?.startLoadImageThread()
                        if flipped { createdViewer?.flipDataSeries(browser) }
                    }
                }
            } else if let movieController {
                addViewerMovieSeries(movieController, viewerPix, NSMutableArray(array: correspondingObjects), volumeData)
            } else if let viewer {
                changeViewerImageData(viewer, viewerPix, NSMutableArray(array: correspondingObjects), volumeData, false)
                movieController = viewer
            } else {
                movieController = allocateViewer(viewerPix, NSMutableArray(array: correspondingObjects), volumeData)
            }
        }

        // "COPYSETTINGS" switched on while opening (fusion, for instance) stays on.
        if !defaults.bool(forKey: "COPYSETTINGS") {
            defaults.set(copyCOPYSETTINGS, forKey: "COPYSETTINGS")
        }
        DCMView.setDontListenToSyncMessage(false)
        return multiFrame
    }
}
