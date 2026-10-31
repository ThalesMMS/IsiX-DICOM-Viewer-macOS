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
import UniformTypeIdentifiers
import CoreData
import IsiXContracts
import IsiXPreferences
import IsiXROI

// The ROI storage and creation of the 2D viewer. ViewerController keeps the
// selectors plugins, menus and the other viewer files send, as façades; the
// work is done here by types of their own that receive the viewer as an
// argument and never keep it:
//
// - ViewerROIArchives reads and writes the ROIs of the images through the
//   ROIStoring port (IsiXContracts), whose app adapter is ViewerROIArchiveStore;
// - ViewerROICreation makes brushes from a mask and layers from a ROI with
//   ROIFromMask (IsiXROI);
// - ViewerROIEdits deletes, renames and selects ROIs by name, and erases or
//   restores the content of a ROI volume;
// - ViewerROINames holds the default names and builds the names a viewer
//   offers with ROINameCatalog (IsiXPreferences);
// - ViewerROIFiles imports and exports ROI files through the open and save panels.
//
// The ROI lists of the viewer are its own mutable arrays (ViewerROISlices),
// which plugins hold and change and the ROI code compares by identity.

/// `[controller windowWillClose]`, for the window controllers that answer it
/// (OSIWindowController and its subclasses, and the auxiliary windows of the
/// viewers); NO for the others. Their -windowWillClose: autoreleased them, so
/// a lookup by nib name made in that pass of the run loop does not reuse one:
/// a window shown again would outlive its controller.
func horosWindowControllerIsClosing(_ controller: NSWindowController?) -> Bool {
    let selector = NSSelectorFromString("windowWillClose")
    guard let controller, controller.responds(to: selector) else { return false }
    typealias Imp = @convention(c) (AnyObject, Selector) -> ObjCBool
    return unsafeBitCast(controller.method(for: selector), to: Imp.self)(controller, selector).boolValue
}

/// The paths of `urls` by importer, in the order they were chosen: JSON
/// interchange files, XML files, .rois_series archives, and the rest (.roi
/// archives), as the extension (in any case) names them.
fileprivate func roiImportGroups(_ urls: [URL]) -> (json: [String], xml: [String], series: [String], roi: [String]) {
    var groups: (json: [String], xml: [String], series: [String], roi: [String]) = ([], [], [], [])
    for url in urls {
        let path = url.path
        switch url.pathExtension.lowercased() {
        case "json": groups.json.append(path)
        case "xml": groups.xml.append(path)
        case "rois_series": groups.series.append(path)
        default: groups.roi.append(path)
        }
    }
    return groups
}

// MARK: - Storage

/// The ROIs of one time point and what saving them needs, copied from the
/// viewer when the save is asked: its images, slices, ROIs and the archives
/// they were loaded from, and the store of their archives.
@MainActor final class ViewerROISaveSnapshot {
    /// The image of each slice; nil where the file list holds something else.
    let fileList: [DicomImage?]
    let pixList: [DCMPix?]
    /// The ROIs of each slice, as they were.
    let roiList: [[ROI]]
    /// The archive each slice's ROIs were loaded from, empty for none.
    let copyRoiList: [Data]
    let store: ViewerROIArchiveStore

    init(fileList: [DicomImage?], pixList: [DCMPix?], roiList: [[ROI]], copyRoiList: [Data], store: ViewerROIArchiveStore) {
        self.fileList = fileList
        self.pixList = pixList
        self.roiList = roiList
        self.copyRoiList = copyRoiList
        self.store = store
    }

    /// The database the ROIs are saved in.
    var database: DicomDatabase { store.database }
}

/// The ROIs of the viewer's images, read when a time point is loaded and
/// written when it is saved, through the `ROIStoring` port of the viewer's
/// process graph: an image's ROIs are one archive, its report, filed by SOP
/// Instance UID and frame. The ROIs of an image shown on every image of the
/// series (an alias) are stored with their own image only, and put back on
/// the other images of the same series when loaded. The volume lengths are
/// stored with the image they were drawn from (their anchor).
@MainActor enum ViewerROIArchives {

    /// The images of the time point `movieIndex`, by slice, and their database.
    private static func images(of viewer: ViewerController, movieIndex: Int) -> (images: [DicomImage?], database: DicomDatabase)? {
        guard let files = viewer.horos_fileList(at: movieIndex), let last = files.lastObject as? NSManagedObject,
              let database = DicomDatabase(for: last.managedObjectContext) else { return nil }
        return (files.map { $0 as? DicomImage }, database)
    }

    /// The store of the archives of `images` and of the volume lengths' anchors of `movieIndex`.
    private static func store(of viewer: ViewerController, movieIndex: Int, images: [DicomImage?],
                              database: DicomDatabase) -> ViewerROIArchiveStore {
        let anchors = viewer.volumeLengthState(forMovieIndex: movieIndex, create: false).map(volumeLengthAnchors) ?? []
        return viewer.sessionGraph.processGraph.roiArchives(of: images.compactMap { $0 } + anchors, in: database)
    }

    /// The images the volume lengths of a time point were drawn from: its anchor and the anchor of each length.
    private static func volumeLengthAnchors(_ state: Any) -> [DicomImage] {
        guard let state = state as? [AnyHashable: Any] else { return [] }
        let anchors = (state["anchors"] as? [AnyHashable: Any])?.values.compactMap { $0 as? DicomImage } ?? []
        return anchors + [state["anchor"] as? DicomImage].compactMap { $0 }
    }

    /// The ROIs in the archive stored for `reference`: none when it has no
    /// archive, nil when the archive cannot be read.
    private static func storedROIs(of reference: ROIImageReference, in store: some ROIStoring) -> [ROI]? {
        guard let stored = store.storedArchive(of: reference) else { return [] }
        return RestrictedUnarchiver.unarchiveROIs(with: stored.archive)?.compactMap { $0 as? ROI }
    }

    /// The time point a volume length belongs to, 0 when it names none.
    private static func temporalIndex(of length: HorosVolumeLengthROI) -> Int {
        switch length.volumeLength?["temporalIndex"] {
        case let number as NSNumber: return number.intValue
        case let text as NSString: return text.integerValue
        default: return 0
        }
    }

    /// Reads the ROIs of the time point `movieIndex` into its slices, when the
    /// ROIs are saved: those of each image that is no reslice, then the
    /// volume lengths, read from their anchor in a reslice.
    static func load(_ viewer: ViewerController, movieIndex: Int) {
        guard viewer.sessionGraph.preferences[ROINameCatalog.savesROIs],
              let (images, database) = images(of: viewer, movieIndex: movieIndex) else { return }
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            let store = store(of: viewer, movieIndex: movieIndex, images: images, database: database)
            let pixList = (viewer.horos_pixList(at: movieIndex) as? [Any] ?? []).map { $0 as? DCMPix }
            let copies = viewer.horos_copyRoiList(at: movieIndex)
            guard let slices = ViewerROISlices(viewer, movie: movieIndex) else { return }
            for (i, image) in images.enumerated() where !isReslice(pixList, i) {
                let reference = image.map(ViewerROIArchiveStore.reference(of:))
                let stored = reference.flatMap(store.storedArchive(of:))
                if i < (copies?.count ?? 0) {
                    copies?.replaceObject(at: i, with: (stored?.savedArchive ?? Data()) as NSData)
                }
                guard let stored else { continue }
                guard let archived = RestrictedUnarchiver.unarchiveROIs(with: stored.archive) else {
                    NSLog("failed to read a ROI")
                    continue
                }
                // An archive may hold something else than ROIs (the restricted
                // unarchiver accepts strings and numbers): it is left out.
                let rois = archived.compactMap { $0 as? ROI }.filter { roi in
                    (roi as? HorosVolumeLengthROI).map { temporalIndex(of: $0) == movieIndex } ?? true
                }
                slices.list(at: i)?.addObjects(from: rois)
                for roi in rois {
                    if let length = roi as? HorosVolumeLengthROI {
                        viewer.register(length, movieIndex: movieIndex, anchor: image)
                    }
                    if roi.isAliased {
                        roi.originalIndexForAlias = Int32(i)
                        // Put back on the other images of the same series.
                        for x in pixList.indices where x != i && (x < images.count ? images[x]?.series : nil) === image?.series {
                            slices.list(at: x)?.add(roi)
                        }
                    }
                }
                for roi in rois {
                    viewer.horos_imageView?.roiSet(roi)
                }
            }
            for length in viewer.volumeLengthROIs(forMovieIndex: movieIndex) ?? [] {
                viewer.attach(length, movieIndex: movieIndex)
            }
            guard isReslice(pixList, 0) else { return }
            // A reslice has no ROIs of its own: its volume lengths are read
            // from the image they were drawn from.
            guard let anchor = viewer.volumeLengthState(forMovieIndex: movieIndex, create: true)?["anchor"] as? DicomImage else { return }
            guard let stored = storedROIs(of: ViewerROIArchiveStore.reference(of: anchor), in: store) else {
                NSLog("*** load ROI exception: %@", "The existing ROI archive could not be read.")
                return
            }
            for case let length as HorosVolumeLengthROI in stored where temporalIndex(of: length) == movieIndex {
                viewer.register(length, movieIndex: movieIndex, anchor: anchor)
                viewer.attach(length, movieIndex: movieIndex)
            }
        }
    }

    /// Whether slice `i` is a reslice, which has no ROIs of its own to store.
    private static func isReslice(_ pixList: [DCMPix?], _ i: Int) -> Bool {
        i < pixList.count && (pixList[i]?.generated ?? false)
    }

    /// Writes the ROIs of the time point `movieIndex` that changed, when the
    /// ROIs are saved. `later`: the viewer keeps going with other slices (a
    /// plane change, another series), so the ROIs are written a few images at
    /// a time on the main thread, from a copy of the lists, instead of all at
    /// once: thousands of brushes took more than a second. A series with
    /// volume lengths, whose anchors are the viewer's state, is saved at once.
    static func save(_ viewer: ViewerController, movieIndex: Int, later: Bool) {
        guard viewer.sessionGraph.preferences[ROINameCatalog.savesROIs],
              let (images, database) = images(of: viewer, movieIndex: movieIndex) else { return }
        let state = viewer.volumeLengthState(forMovieIndex: movieIndex, create: false) as? [AnyHashable: Any]
        let volumeLengths = (state?["anchors"] as? [AnyHashable: Any])?.isEmpty == false
        N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
            let pixList = (viewer.horos_pixList(at: movieIndex) as? [Any] ?? []).map { $0 as? DCMPix }
            let copies = (viewer.horos_copyRoiList(at: movieIndex) as? [Any] ?? []).map { $0 as? Data ?? Data() }
            let snapshot = ViewerROISaveSnapshot(fileList: images, pixList: pixList,
                                                 roiList: ViewerROISlices(viewer, movie: movieIndex)?.all ?? [],
                                                 copyRoiList: copies,
                                                 store: store(of: viewer, movieIndex: movieIndex, images: images, database: database))
            if later && !volumeLengths {
                ROISaveJob(snapshot: snapshot).start()
                return
            }
            var written: [String] = []
            var anchorPaths: [AnyHashable: Any] = [:]
            for i in images.indices {
                guard let path = archiveROIs(of: i, in: snapshot, volumeLengths: volumeLengths) else { continue }
                written.append(path)
                if let key = images[i]?.objectID as AnyHashable? { anchorPaths[key] = path }
            }
            if volumeLengths && !anchorsAreReadable(state, written: anchorPaths, in: snapshot.store) {
                NSLog("-[ViewerController saveROI:]: %@", "The existing ROI archive could not be read.")
                return
            }
            // The volume lengths add the files they write to the list.
            let paths = NSMutableArray(array: written)
            viewer.saveVolumeLengthROIs(movieIndex, writtenPaths: paths, anchorPaths: anchorPaths)
            snapshot.store.index(paths.compactMap { $0 as? String })
        }
    }

    /// Whether the archive of every anchor not written by this save can be
    /// read: one that cannot is never replaced by the volume lengths alone.
    private static func anchorsAreReadable(_ state: [AnyHashable: Any]?, written: [AnyHashable: Any],
                                           in store: ViewerROIArchiveStore) -> Bool {
        let anchors = (state?["anchors"] as? [AnyHashable: Any])?.values.compactMap { $0 as? DicomImage } ?? []
        return anchors.allSatisfy { anchor in
            (anchor.objectID as AnyHashable?).flatMap { written[$0] } != nil || storedROIs(of: ViewerROIArchiveStore.reference(of: anchor), in: store) != nil
        }
    }

    /// Writes the ROIs of slice `i` of the snapshot as the report of its
    /// image, when they changed since they were loaded; returns the file
    /// written, or nil. The ROIs shown on every image are stored with their
    /// own image only, and the volume lengths with their anchor; with
    /// `volumeLengths`, those already stored stay.
    static func archiveROIs(of i: Int, in snapshot: ViewerROISaveSnapshot, volumeLengths: Bool) -> String? {
        guard i < snapshot.pixList.count, snapshot.pixList[i]?.generated != true,
              i < snapshot.fileList.count, let image = snapshot.fileList[i] else { return nil }
        let store = snapshot.store
        let reference = ViewerROIArchiveStore.reference(of: image)
        return autoreleasepool { () -> String? in
            guard let destination = store.destination(of: reference) else { return nil }
            var rois = (i < snapshot.roiList.count ? snapshot.roiList[i] : []).filter { roi in
                if roi is HorosVolumeLengthROI { return false }
                roi.pix = snapshot.pixList[i]
                return !(roi.isAliased && Int32(i) != roi.originalIndexForAlias)
            }
            if volumeLengths && !destination.replacesFormerFile {
                guard let stored = storedROIs(of: reference, in: store) else {
                    NSLog("saveROI failed: %@", "The existing ROI archive could not be read.")
                    return nil
                }
                rois += stored.filter { $0 is HorosVolumeLengthROI }
            }
            let loaded = i < snapshot.copyRoiList.count ? snapshot.copyRoiList[i] : Data()
            guard destination.needsWriting(roiCount: rois.count, unchanged: {
                identical(RestrictedUnarchiver.unarchiveROIs(with: loaded).map { Array($0) } ?? [], rois)
            }) else { return nil }
            do {
                // The reports carry the typedstream of the array, as released versions read it.
                let archive = try HistoricalArchive.archivedData(withRootObject: NSArray(array: rois))
                return store.write(archive, to: destination, of: reference) ? destination.path : nil
            } catch {
                NSLog("saveROI failed: %@", "\(error)")
                return nil
            }
        }
    }

    /// Whether two lists of ROIs are the same, ROI by ROI, in their persisted
    /// form: ROI.data, the archive every encoded field is part of.
    nonisolated static func identical(_ saved: [Any], _ current: [Any]) -> Bool {
        guard saved.count == current.count else { return false }
        return zip(saved, current).allSatisfy { saved, current in
            guard let data = (current as? ROI)?.data else { return false }
            return data == (saved as? ROI)?.data
        }
    }
}

// MARK: - Creation

/// The ROIs the viewer makes from a buffer: brushes from a mask of labels,
/// one per label and per image, and layer ROIs, an image over the current
/// one. The arithmetic is ROIFromMask's; each new ROI goes into the slice's
/// list and is announced, as a ROI drawn by hand.
@MainActor enum ViewerROICreation {

    /// The current image of the viewer and its slices.
    private static func currentImage(of viewer: ViewerController) -> (pix: DCMPix?, index: Int, depth: Int) {
        let index = Int(viewer.horos_imageView?.curImage ?? 0)
        let slices = viewer.pixList() as? [Any] ?? []
        return (index < slices.count ? slices[index] as? DCMPix : nil, index, slices.count)
    }

    /// The labels of `mask`: the current image's, or, for `fullStack`, those of
    /// every image of the series, one after the other.
    static func labels(of viewer: ViewerController, in mask: UnsafeMutablePointer<UInt8>?, fullStack: Bool) -> [UInt8] {
        let (pix, _, depth) = currentImage(of: viewer)
        guard let mask, let pix else { return [] }
        let count = pix.pwidth * pix.pheight * (fullStack ? depth : 1)
        return ROIFromMask.labels(in: UnsafeBufferPointer(start: mask, count: count))
    }

    /// The colour of the `index`-th label, as a ROI keeps it.
    static func colour(ofRegion index: Int) -> RGBColor {
        let colour = ROIFromMask.colour(ofRegion: index)
        return RGBColor(red: colour.red, green: colour.green, blue: colour.blue)
    }

    /// Adds a brush of the pixels of `label` in `mask` to the current image,
    /// or, for `fullStack`, to each image of the series that has some.
    static func addBrushes(to viewer: ViewerController, from mask: UnsafeMutablePointer<UInt8>?, label: UInt8,
                           colour: RGBColor, name: String?, fullStack: Bool) {
        let (pix, current, depth) = currentImage(of: viewer)
        guard let mask, let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return }
        let width = pix?.pwidth ?? 0, height = pix?.pheight ?? 0
        for k in fullStack ? 0..<depth : 0..<1 {
            let slice = UnsafeBufferPointer(start: mask + k * width * height, count: width * height)
            guard let region = ROIFromMask.region(of: label, in: slice, width: width, height: height) else { continue }
            var texture = region.texture
            let roi = texture.withUnsafeMutableBufferPointer { texture in
                ROI(texture: texture.baseAddress, textWidth: region.width, textHeight: region.height,
                    textName: ROIFromMask.name(name, label: label), positionX: region.x, positionY: region.y,
                    spacingX: Float(pix?.pixelSpacingX ?? 0), spacingY: Float(pix?.pixelSpacingY ?? 0),
                    imageOrigin: NSPoint(x: CGFloat(pix?.originX ?? 0), y: CGFloat(pix?.originY ?? 0)))
            }
            guard let roi else { continue }
            roi.rgbcolor = colour
            slices.list(at: fullStack ? k : current)?.add(roi)
            ViewerROIEdits.post(.OsirixROIChange, roi)
        }
    }

    /// A layer ROI of `image` on the current image, selected.
    static func addLayer(to viewer: ViewerController, image: NSImage?, referenceFilePath path: String?,
                         layerPixelSpacingX: Float, layerPixelSpacingY: Float) -> ROI? {
        let pix = currentImage(of: viewer).pix
        guard let roi = ROI(type: .tLayerROI, Float(pix?.pixelSpacingX ?? 0), Float(pix?.pixelSpacingY ?? 0),
                            DCMPix.originCorrected(accordingToOrientation: pix)) else { return nil }
        roi.layerPixelSpacingX = layerPixelSpacingX
        roi.layerPixelSpacingY = layerPixelSpacingY
        roi.layerReferenceFilePath = path
        roi.layerImage = image
        ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex))?.list(at: currentImage(of: viewer).index)?.add(roi)
        ViewerROIEdits.post(.OsirixROIChange, roi)
        viewer.select(roi, deselectingOther: true)
        return roi
    }

    /// A layer ROI of the values inside `roi`, drawn through the window of
    /// the image, beside the ROI and selected; nil for a ROI without an area
    /// (a text, a length, an arrow, a point) or without values.
    static func layer(from roi: ROI?, in viewer: ViewerController) -> ROI? {
        guard let roi, ![ToolMode.tText, .tMesure, .tArrow, .t2DPoint].contains(roi.type) else { return nil }
        var count = 0
        var locations: UnsafeMutablePointer<Float>? = nil
        let values = roi.curView?.curDCM?.getROIValue(&count, roi, &locations)
        defer {
            free(values)
            free(locations)
        }
        // A spline of two points or fewer has no value at all.
        guard let values, let locations, count > 0,
              let layer = ROIFromMask.Layer(locations: locations, count: count) else { return nil }
        NSLog("imageWidth : %d, imageHeight: %d", layer.width, layer.height)
        // A picture that cannot be made (a size out of range) has no layer.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(layer.width), pixelsHigh: Int(layer.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .calibratedRGB, bytesPerRow: Int(layer.width &* 4), bitsPerPixel: 32),
              let pixels = bitmap.bitmapData else { return nil }
        var windowLevel: Float = 0, windowWidth: Float = 0
        viewer.horos_imageView?.getWLWW(&windowLevel, &windowWidth)
        let pix = viewer.horos_imageView?.curDCM
        layer.draw(values: values, locations: locations, count: count, windowLevel: windowLevel, windowWidth: windowWidth,
                   isRGB: pix?.isRGB ?? false, into: pixels, bytesPerRow: Int32(truncatingIfNeeded: bitmap.bytesPerRow))
        let image = NSImage()
        image.addRepresentation(bitmap)
        NSLog("image: %f, %f", image.size.width, image.size.height)
        NSLog("pixelSpacing: %f, %f", pix?.pixelSpacingX ?? 0, pix?.pixelSpacingY ?? 0)
        guard let newROI = viewer.addLayerRoiToCurrentSlice(with: image, referenceFilePath: "none",
                                                            layerPixelSpacingX: Float(pix?.pixelSpacingX ?? 0),
                                                            layerPixelSpacingY: Float(pix?.pixelSpacingY ?? 0)) else { return nil }
        newROI.name = "\(roi.name ?? "(null)") \(NSLocalizedString("Layer", comment: ""))"
        newROI.isLayerOpacityConstant = false
        newROI.canColorizeLayer = true
        // Beside the ROI: its lower right corner 10 pixels right of and above
        // that of the values.
        let corner = newROI.lowerRightPoint()
        let dx = Float(CGFloat(layer.maxX) - corner.x + 10), dy = Float(CGFloat(layer.maxY) - corner.y - 10)
        for case let point as MyPoint in newROI.points as? [Any] ?? [] {
            point.move(dx, dy)
        }
        viewer.select(newROI, deselectingOther: true)
        return newROI
    }
}

// MARK: - Edits by name

/// What the viewer does to its ROIs by name: delete and rename them in every
/// image of the current time point, delete the ROIs a morphing generated,
/// select them all, and erase or restore the pixels of a ROI volume.
@MainActor enum ViewerROIEdits {

    /// Announces a change of `roi` to the views, windows and plugins.
    static func post(_ name: NSNotification.Name, _ roi: Any?) {
        NotificationCenter.default.post(name: name, object: roi, userInfo: nil)
    }

    /// Removes from every image of the current time point the ROIs `matching`
    /// asks for, each announced first; returns how many.
    @discardableResult
    static func remove(from viewer: ViewerController, matching: (ROI) -> Bool) -> Int {
        guard let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return 0 }
        var removed = 0
        for index in 0..<slices.count {
            guard let list = slices.list(at: index) else { continue }
            var i = 0
            while i < list.count {
                guard let roi = list.object(at: i) as? ROI, matching(roi) else {
                    i += 1
                    continue
                }
                post(.OsirixRemoveROI, roi)
                list.remove(roi)
                removed += 1
            }
        }
        return removed
    }

    /// Renames the ROIs called `name` in every image of the current time point.
    static func rename(_ name: String?, to newName: String?, in viewer: ViewerController) {
        guard let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return }
        for index in 0..<slices.count {
            for roi in slices.rois(at: index) where name != nil && roi.name == name {
                roi.name = newName
                post(.OsirixROIChange, roi)
            }
        }
    }

    /// Selects every ROI of the current time point, or none.
    static func selectAll(_ select: Bool, in viewer: ViewerController) {
        viewer.add(toUndoQueue: "roi")
        guard let slices = ViewerROISlices(viewer, movie: Int(viewer.horos_curMovieIndex)) else { return }
        for index in 0..<slices.count {
            for roi in slices.rois(at: index) {
                roi.roImode = select ? ROI_selected : ROI_sleep
            }
        }
        viewer.horos_imageView?.needsDisplay = true
    }

    /// Deletes the unlocked ROIs called `name`, as one undo step.
    static func deleteUnlocked(named name: String?, in viewer: ViewerController) {
        viewer.add(toUndoQueue: "roi")
        remove(from: viewer) { name != nil && $0.name == name && !$0.locked }
        viewer.imageView()?.needsDisplay = true
    }

    /// Deletes the ROIs a morphing generated, those called `name` or all of
    /// them, after saving every time point, as one undo step; returns how many.
    static func deleteGenerated(named name: String?, in viewer: ViewerController) -> Int32 {
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            viewer.saveROI(movie)
        }
        viewer.add(toUndoQueue: "roi")
        viewer.horos_imageView?.stopROIEditingForce(true)
        let removed = remove(from: viewer) { $0.comments == "morphing generated" && (name == nil || $0.name == name) }
        viewer.horos_imageView?.setIndex(viewer.horos_imageView?.curImage ?? 0)
        return Int32(removed)
    }

    // MARK: Volume content

    /// Erase Content rewrites the pixel data of every image of the series that
    /// contains a ROI with the selected name. Undo only tracks ROI objects, so
    /// the user is warned once (with an opt-out) that the pixels can only be
    /// brought back with ROI Volume > Restore Content.
    static func confirmErase(named name: String?, in viewer: ViewerController) -> Bool {
        let preferences = viewer.sessionGraph.preferences
        if preferences[ROINameCatalog.skipsEraseContentWarning] {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString("Erase the content of ROI \u{201c}%@\u{201d} in the whole series?", comment: ""),
                                   (name ?? "(null)") as NSString)
        alert.informativeText = NSLocalizedString("The pixels inside every ROI with this name will be replaced in memory, on all images of the series. Undo does not revert pixel data: use ROI Volume > Restore Content to reload the original pixels from disk.", comment: "")
        alert.addButton(withTitle: NSLocalizedString("Erase", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = NSLocalizedString("Do not ask again", comment: "")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            preferences.set(true, for: ROINameCatalog.skipsEraseContentWarning)
        }
        return true
    }

    /// Erases (`restore` false) or restores the content of the selected ROI's
    /// volume in every image of the series, then measures every ROI again.
    static func eraseOrRestoreVolume(restore: Bool, in viewer: ViewerController) {
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            viewer.saveROI(movie)
        }
        _ = viewer.computeInterval()
        guard let selected = viewer.selectedROI() else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: NSLocalizedString("Select a ROI.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        if !restore && viewer.confirmROIVolumeErase(forName: selected.name) == false {
            return
        }
        var error: NSString? = nil
        _ = viewer.computeVolume(selected, points: nil, generateMissingROIs: true, generatedROIs: nil, computeData: nil, error: &error)
        if let error {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Volume Error", comment: ""), message: error as String, defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let current = Int(viewer.horos_curMovieIndex)
        if restore {
            viewer.roiSetPixels(selected, 0, false, false, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, 0, true)
        } else {
            let minimum = (viewer.horos_pixList(at: current)?.firstObject as? DCMPix)?.minValueOfSeries ?? 0
            viewer.roiSetPixels(selected, 0, false, false, -Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude, minimum, false)
        }
        // The window level again, then every ROI measured again.
        var level: Float = 0, width: Float = 0
        viewer.horos_imageView?.getWLWW(&level, &width)
        viewer.horos_imageView?.setWLWW(level, width)
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            let slices = ViewerROISlices(viewer, movie: movie)
            for (index, pix) in (viewer.horos_pixList(at: movie) as? [Any] ?? []).enumerated() {
                for roi in slices?.rois(at: index) ?? [] { roi.recompute() }
                (pix as? DCMPix)?.changeWLWW(level, width)
            }
        }
        post(.OsirixUpdateVolumeData, viewer.horos_pixList(at: current))
    }
}

// MARK: - Names

/// The names of ROIs a viewer offers in its menus: the default names every
/// viewer shares, which plugins may replace, then those of its own ROIs.
@MainActor enum ViewerROINames {
    /// The default names as they were given, the object plugins set and read
    /// back (the plugin manager gives a mutable array, which plugins may change).
    static var defaults: NSArray? = nil

    /// The names `viewer` offers now, published in its state.
    static func names(of viewer: ViewerController) -> [String] {
        var found: [String?] = []
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            guard let slices = ViewerROISlices(viewer, movie: movie) else { continue }
            for index in 0..<min(slices.count, viewer.horos_pixList(at: movie)?.count ?? 0) {
                found += slices.rois(at: index).map(\.name)
            }
        }
        let names = ROINameCatalog.names(defaults: (defaults as? [Any] ?? []).compactMap { $0 as? String }, found: found)
        viewer.horos_ROINamesArray = names
        return names
    }
}

// MARK: - Files

/// The ROI files the viewer imports and exports through its panels.
@MainActor enum ViewerROIFiles {

    /// Asks for ROI files and imports them.
    static func chooseAndLoad(into viewer: ViewerController) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "roi")!, UTType(filenameExtension: "rois_series")!, UTType(filenameExtension: "xml")!, UTType(filenameExtension: "json")!]
        panel.begin { result in
            if result == .OK { load(panel.urls, into: viewer) }
        }
    }

    /// Imports the files chosen, each by the importer of its own extension:
    /// the JSON interchange files, the XML files, each .rois_series archive,
    /// and the .roi archives together.
    static func load(_ urls: [URL], into viewer: ViewerController) {
        let groups = roiImportGroups(urls)
        for path in groups.json {
            viewer.roiLoadFromInterchangeFile(path)
        }
        if !groups.xml.isEmpty {
            viewer.horos_imageView?.roiLoad(fromXMLFiles: groups.xml)
        }
        for path in groups.series {
            viewer.roiLoad(fromSeries: path)
        }
        if !groups.roi.isEmpty {
            do {
                try viewer.importROIFiles(groups.roi)
            } catch {
                viewer.presentROIImportError(forPath: groups.roi.last ?? "", error: error)
            }
        }
    }

    /// Imports a .rois_series archive; a nil path reaches the importer as an empty one.
    static func loadSeries(_ path: String?, into viewer: ViewerController) {
        do {
            try viewer.importROIArchive(fromPath: path ?? "")
        } catch {
            viewer.presentROIImportError(forPath: path ?? "", error: error)
        }
    }

    /// Asks where to save the ROIs of every image of every time point as a
    /// .rois_series archive, or says there are none.
    static func chooseAndSaveSeries(of viewer: ViewerController) {
        var perMovie: [[[ROI]]] = []
        for movie in 0..<Int(viewer.horos_maxMovieIndex) {
            let slices = ViewerROISlices(viewer, movie: movie)
            perMovie.append((0..<(viewer.horos_pixList(at: movie)?.count ?? 0)).map { slices?.rois(at: $0) ?? [] })
        }
        guard perMovie.contains(where: { $0.contains { !$0.isEmpty } }) else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Save Error", comment: ""), message: NSLocalizedString("No ROIs in this series!", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        let panel = NSSavePanel()
        panel.canSelectHiddenExtension = false
        panel.allowedContentTypes = [UTType(filenameExtension: "rois_series")!]
        panel.nameFieldStringValue = (viewer.fileList()?.firstObject as? DicomImage)?.series?.name ?? ""
        panel.begin { result in
            // Compatibility: .rois_series is the typedstream of arrays of
            // mutable arrays that released Horos/OsiriX and the restricted
            // ROI importer read, not a keyed archive.
            guard result == .OK, let path = panel.url?.path else { return }
            let archive = NSMutableArray(array: perMovie.map { movie in NSMutableArray(array: movie.map { NSMutableArray(array: $0) }) })
            _ = try? HistoricalArchive.archiveRootObject(archive, toFile: path)
        }
    }
}

// MARK: - The selectors

public extension ViewerController {

    @objc(defaultROINames)
    class func defaultROINames() -> NSArray! {
        ViewerROINames.defaults
    }

    @objc(setDefaultROINames:)
    class func setDefaultROINames(_ rn: NSArray!) {
        ViewerROINames.defaults = rn
    }

    @objc(loadROI:)
    func loadROI(_ mIndex: Int) {
        ViewerROIArchives.load(self, movieIndex: mIndex)
    }

    @objc(areROIsArraysIdentical:with:)
    class func areROIsArraysIdentical(_ copy: NSArray!, with roisArray: NSArray!) -> Bool {
        ViewerROIArchives.identical(copy as? [Any] ?? [], roisArray as? [Any] ?? [])
    }

    @objc(flipROIHorizontally:)
    @IBAction func flipROIHorizontally(_ sender: Any!) {
        for case let roi as ROI in selectedROIs() as? [Any] ?? [] { roi.flipVertically(false) }
    }

    @objc(flipROIVertically:)
    @IBAction func flipROIVertically(_ sender: Any!) {
        for case let roi as ROI in selectedROIs() as? [Any] ?? [] { roi.flipVertically(true) }
    }

    @objc(saveROI:)
    func saveROI(_ mIndex: Int) {
        saveROI(mIndex, later: false)
    }

    /// The type of what a save copies from the viewer, as ROISaveJob names it.
    internal typealias ROISaveSnapshot = ViewerROISaveSnapshot

    @objc(saveROI:later:)
    func saveROI(_ mIndex: Int, later: Bool) {
        ViewerROIArchives.save(self, movieIndex: mIndex, later: later)
    }

    /// Writes the ROIs of slice `i` of the snapshot; returns the file written, or nil.
    internal static func archiveROIs(of i: Int, in snapshot: ROISaveSnapshot, volumeLengths: Bool) -> String? {
        ViewerROIArchives.archiveROIs(of: i, in: snapshot, volumeLengths: volumeLengths)
    }

    // -newROI: stays in ViewerController.m (a "new" method returning an
    // object it does not own).

    @objc(containsROI:)
    func contains(_ roi: ROI!) -> Bool {
        guard let roi, let slices = ViewerROISlices(self, movie: Int(horos_curMovieIndex)) else { return false }
        return (0..<slices.count).contains { slices.rois(at: $0).contains { $0 === roi } }
    }

    @objc(generateROINamesArray)
    func generateROINamesArray() -> NSMutableArray! {
        NSMutableArray(array: ViewerROINames.names(of: self))
    }

    @objc(imageForROI:)
    func image(forROI i: ToolMode) -> NSImage! {
        let names: [ToolMode: String] = [
            .tWL: "WLWW", .tZoom: "Zoom", .tTranslate: "Move", .tRotate: "Rotate", .tNext: "Stack", .tMesure: "Length",
            .tAngle: "Angle", .tROI: "Rectangle", .tOval: "Oval", .tText: "Text", .tArrow: "Arrow",
            .tOPolygon: "Opened Polygon", .tCPolygon: "Closed Polygon", .tPencil: "Pencil", .t2DPoint: "Point",
            .tPlain: "Brush", .tRepulsor: "Repulsor", .tROISelector: "ROISelector", .tAxis: "Axis",
            .tDynAngle: "DynamicAngle", .tTAGT: "PerpendicularLines",
        ]
        return names[i].flatMap { NSImage(named: $0) }
    }

    /// Shows the ROI manager window, or opens one.
    @objc(roiGetManager:)
    @IBAction func roiGetManager(_ sender: Any!) {
        let open = NSApp.windows.filter {
            $0.windowController?.windowNibName == "ROIManager" && !horosWindowControllerIsClosing($0.windowController)
        }
        for window in open { window.makeKeyAndOrderFront(self) }
        guard open.isEmpty else { return }
        let manager = ROIManagerController(viewer: self)
        // The manager releases itself when its window closes (-windowWillClose:).
        _ = Unmanaged.passRetained(manager)
        manager.showWindow(self)
        manager.window?.makeKeyAndOrderFront(self)
    }

    @objc(addRoiFromFullStackBuffer:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!) {
        addRoi(fromFullStackBuffer: buff, withName: "")
    }

    @objc(addPlainRoiToCurrentSliceFromBuffer:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!) {
        addPlainRoiToCurrentSlice(fromBuffer: buff, withName: "")
    }

    @objc(addPlainRoiToCurrentSliceFromBuffer:withName:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!, withName name: String!) {
        for (index, label) in ViewerROICreation.labels(of: self, in: buff, fullStack: false).enumerated() {
            addPlainRoiToCurrentSlice(fromBuffer: buff, forSpecificValue: label, with: ViewerROICreation.colour(ofRegion: index), withName: name)
        }
    }

    @objc(addPlainRoiToCurrentSliceFromBuffer:forSpecificValue:withColor:withName:)
    func addPlainRoiToCurrentSlice(fromBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor, withName name: String!) {
        ViewerROICreation.addBrushes(to: self, from: buff, label: value, colour: aColor, name: name, fullStack: false)
    }

    @objc(addRoiFromFullStackBuffer:withName:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, withName name: String!) {
        for (index, label) in ViewerROICreation.labels(of: self, in: buff, fullStack: true).enumerated() {
            addRoi(fromFullStackBuffer: buff, forSpecificValue: label, with: ViewerROICreation.colour(ofRegion: index), withName: name)
        }
    }

    @objc(addRoiFromFullStackBuffer:forSpecificValue:withColor:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor) {
        addRoi(fromFullStackBuffer: buff, forSpecificValue: value, with: aColor, withName: "")
    }

    @objc(addRoiFromFullStackBuffer:forSpecificValue:withColor:withName:)
    func addRoi(fromFullStackBuffer buff: UnsafeMutablePointer<UInt8>!, forSpecificValue value: UInt8, with aColor: RGBColor, withName name: String!) {
        ViewerROICreation.addBrushes(to: self, from: buff, label: value, colour: aColor, name: name, fullStack: true)
    }

    @objc(addLayerRoiToCurrentSliceWithImage:referenceFilePath:layerPixelSpacingX:layerPixelSpacingY:)
    func addLayerRoiToCurrentSlice(with image: NSImage!, referenceFilePath path: String!, layerPixelSpacingX: Float, layerPixelSpacingY: Float) -> ROI! {
        ViewerROICreation.addLayer(to: self, image: image, referenceFilePath: path,
                                   layerPixelSpacingX: layerPixelSpacingX, layerPixelSpacingY: layerPixelSpacingY)
    }

    @objc(createLayerROIFromROI:)
    func createLayerROI(from roi: ROI!) -> ROI! {
        ViewerROICreation.layer(from: roi, in: self)
    }

    @objc(createLayerROIFromSelectedROI)
    func createLayerROIFromSelectedROI() {
        _ = createLayerROI(from: selectedROI())
    }

    @objc(createLayerROIFromSelectedROI:)
    @IBAction func createLayerROIFromSelectedROI(_ sender: Any!) {
        createLayerROIFromSelectedROI()
    }

    @objc(deleteROI:)
    func delete(_ roi: ROI!) {
        horos_imageView?.stopROIEditingForce(true)
        ViewerROIEdits.remove(from: self) { $0 === roi }
    }

    @objc(deleteSeriesROIwithName:)
    func deleteSeriesROIwithName(_ name: String!) {
        horos_imageView?.stopROIEditingForce(true)
        ViewerROIEdits.remove(from: self) { name != nil && $0.name == name }
    }

    @objc(renameSeriesROIwithName:newName:)
    func renameSeriesROIwithName(_ name: String!, newName newString: String!) {
        ViewerROIEdits.rename(name, to: newString, in: self)
    }

    @objc(roiLoadFromSeries:)
    func roiLoad(fromSeries filename: String!) {
        ViewerROIFiles.loadSeries(filename, into: self)
    }

    @objc(roiLoadFromFiles:)
    @IBAction func roiLoadFromFiles(_ sender: Any!) {
        ViewerROIFiles.chooseAndLoad(into: self)
    }

    @objc(roiSaveSeries:)
    @IBAction func roiSaveSeries(_ sender: Any!) {
        ViewerROIFiles.chooseAndSaveSeries(of: self)
    }

    @objc(roiSelectDeselectAll:)
    @IBAction func roiSelectDeselectAll(_ sender: Any!) {
        ViewerROIEdits.selectAll(ViewerSender.tag(sender) != 0, in: self)
    }

    @objc(confirmROIVolumeEraseForName:)
    func confirmROIVolumeErase(forName name: String!) -> Bool {
        ViewerROIEdits.confirmErase(named: name, in: self)
    }

    @objc(roiVolumeEraseRestore:)
    @IBAction func roiVolumeEraseRestore(_ sender: Any!) {
        ViewerROIEdits.eraseOrRestoreVolume(restore: ViewerSender.tag(sender) != 0, in: self)
    }

    @objc(roiIntDeleteAllROIsWithSameName:)
    func roiIntDeleteAllROIs(withSameName name: String!) {
        ViewerROIEdits.deleteUnlocked(named: name, in: self)
    }

    @objc(roiDeleteAllROIsWithSameName:)
    @IBAction func roiDeleteAllROIsWithSameName(_ sender: Any!) {
        guard let selected = selectedROI() else {
            HorosAlertPanel.runCritical(title: NSLocalizedString("ROIs Error", comment: ""), message: NSLocalizedString("Select a ROI to delete all ROIs with the same name.", comment: ""), defaultButton: NSLocalizedString("OK", comment: ""), alternateButton: nil, otherButton: nil)
            return
        }
        roiIntDeleteAllROIs(withSameName: selected.name)
    }

    @objc(roiDeleteWithName:)
    func roiDelete(withName name: String!) {
        roiIntDeleteAllROIs(withSameName: name)
    }

    @objc(roiIntDeleteGeneratedROIsForName:)
    func roiIntDeleteGeneratedROIs(forName name: String!) -> Int32 {
        ViewerROIEdits.deleteGenerated(named: name, in: self)
    }

    @objc(roiDeleteGeneratedROIsForName:)
    func roiDeleteGeneratedROIs(forName name: String!) {
        _ = roiIntDeleteGeneratedROIs(forName: name)
    }

    @objc(roiDeleteGeneratedROIs:)
    @IBAction func roiDeleteGeneratedROIs(_ sender: Any!) {
        roiDeleteGeneratedROIs(forName: nil)
    }
}
