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
import CoreData
import UniformTypeIdentifiers
import IsiXDICOMFile
import IsiXImaging

// The thumbnails of the selected row: the database preview asks for them with
// a ThumbnailRequest when the selection changes, and ThumbnailLoader makes them
// from the database's series thumbnails or by decoding each image with DCMPix,
// handing what it made to the main actor as ThumbnailBatch values. A new
// selection, or the database switching, cancels the load in progress.

/// What a thumbnail load is asked for, taken on the main actor when the
/// selection changes: the images, one thumbnail each, and the preview list and
/// generation the load belongs to, so that a batch arriving after the
/// selection changed is discarded.
///
/// `@unchecked Sendable`: the request is handed to the loader alone. The
/// database is read through a context of the loader's own, the preview list is
/// only compared by identity, and the preview state is written under the lock
/// of its thumbnails, as before.
struct ThumbnailRequest: @unchecked Sendable {
    let objectIDs: [NSManagedObjectID]
    /// Whether the row is a series, whose images get their own thumbnails;
    /// for a study, each series' thumbnail stored in the database is used.
    let imageLevel: Bool
    let database: DicomDatabase?
    /// The preview list that was shown when the load was asked for, only
    /// compared by identity.
    let list: AnyObject?
    let generation: UInt
    /// The thumbnail of a file that cannot be read.
    let notFound: NSImage
    /// The preview's state, which keeps when the thumbnails were last shown.
    let state: BrowserPreviewState
}

/// What a load has made so far: a thumbnail for each image, and the frames
/// made for the images done.
///
/// `@unchecked Sendable`: a batch is made by the loader and only read by the
/// main actor once it is handed over.
struct ThumbnailBatch: @unchecked Sendable {
    let list: AnyObject?
    let generation: UInt
    var thumbnails: [NSImage]
    var frames: [DCMPix] = []
    /// Whether the load was cancelled when this batch was made.
    var cancelled = false
}

/// One load of thumbnails, which a new selection or the database switching
/// cancels.
final class ThumbnailLoad: Sendable {
    private let task: Task<Void, Never>

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task.cancel()
    }
}

/// A frame lent across the main actor: the preview copies its pixels, and a
/// copy is owned by the one that asked.
struct LentPreviewFrame: @unchecked Sendable {
    let pix: DCMPix?
}

/// The maker of the thumbnails of the database preview, an actor on a serial
/// queue of its own, so that the decodes never hold a thread of Swift
/// concurrency. A load asked while another runs starts once the other has
/// seen its cancellation, after the image it was decoding.
actor ThumbnailLoader {

    private let queue = DispatchSerialQueue(label: "Thumbnails", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Makes the thumbnails of `request` until it is done or cancelled,
    /// handing `deliver` on the main actor what it made: every half second
    /// while it works, unless cancelled, and once at the end, cancelled or not.
    func load(_ request: ThumbnailRequest, deliver: @escaping @MainActor @Sendable (_ batch: ThumbnailBatch, _ final: Bool) -> Void) {
        // A context of the loader's own, read inside -performBlockAndWait:.
        let database = request.database?.privateQueueIndependentDatabase() as? DicomDatabase
        let made = Self.make(request, database: database, isCancelled: { Task.isCancelled }, progress: { batch in
            if Task.isCancelled { return }
            Task { @MainActor in deliver(batch, false) }
        })
        if let made {
            Task { @MainActor in deliver(made, true) }
        }
    }

    /// The thumbnails of `request`, made on the calling thread with
    /// `database`: on the main actor for the few thumbnails a series makes,
    /// on the loader otherwise. Nil when the load was cancelled before it
    /// began. `progress`, when given, is handed the batch made so far every
    /// half second, unless the load is cancelled.
    nonisolated static func make(_ request: ThumbnailRequest, database: DicomDatabase?, isCancelled: () -> Bool,
                                 progress: ((ThumbnailBatch) -> Void)?) -> ThumbnailBatch? {
        autoreleasepool { () -> ThumbnailBatch? in
            if isCancelled() { return nil }
            var batch = ThumbnailBatch(list: request.list, generation: request.generation,
                                       thumbnails: Array(repeating: request.notFound, count: request.objectIDs.count))
            let remote = !(database?.isLocal() ?? false)

            if let raised = HorosObjCException.caught({
                for (i, objectID) in request.objectIDs.enumerated() {
                    if isCancelled() { break }
                    if i != 0, let progress {
                        // Shown on a delayed basis only.
                        let now = Date.timeIntervalSinceReferenceDate
                        if now - request.state.timeIntervalOfLastLoadIconsDisplayIcons > 0.5 {
                            request.state.timeIntervalOfLastLoadIconsDisplayIcons = now
                            progress(batch)
                        }
                    }

                    var made: (thumbnail: NSImage, pix: DCMPix?)?
                    var gone = false
                    N2ManagedObjectContextPerformAndWait(database?.managedObjectContext) {
                        if let raised = HorosObjCException.caught({
                            // The object no longer exists: the selection has very likely changed.
                            guard let image = database?.object(withID: objectID) as? DicomImage else {
                                gone = true
                                return
                            }
                            made = thumbnail(of: image, imageLevel: request.imageLevel, notFound: request.notFound, remote: remote)
                        }) {
                            BrowserObjC.log(raised, stack: true, "-[BrowserController matrixLoadIcons:]")
                        }
                    }
                    if gone { break }
                    // No image from this one (an exception, no file...): the "not found" icon.
                    let thumbnail = made ?? (request.notFound, BrowserController.horos_emptyPreviewPix())
                    batch.thumbnails[i] = thumbnail.thumbnail
                    if let pix = thumbnail.pix { batch.frames.append(pix) }
                }
            }) {
                BrowserObjC.log(raised, stack: true, "-[BrowserController matrixLoadIcons:]")
            }
            batch.cancelled = isCancelled()
            return batch
        }
    }

    /// The thumbnail of one image and its frame: the series' thumbnail stored
    /// in the database for a study, a page for a report or a PDF, the image
    /// decoded otherwise. Nil when the image cannot be decoded.
    private nonisolated static func thumbnail(of image: DicomImage, imageLevel: Bool, notFound: NSImage,
                                              remote: Bool) -> (thumbnail: NSImage, pix: DCMPix?)? {
        var frame: Int32 = 0
        if (image.numberOfFrames?.int32Value ?? 0) > 1 {
            frame = (image.numberOfFrames?.int32Value ?? 0) / 2
        }
        if let frameID = image.frameID { frame = frameID.int32Value }

        let pix: DCMPix? = BrowserPreviewPane.lentFrame(path: image.completePath(), frame: frame,
                                               expected: BrowserController.horos_previewFrame(for: image, frame: frame))
            ?? DCMPix(path: image.completePath(), 0, 1, nil, Int(frame), 0, isBonjour: remote, imageObj: image)

        if !imageLevel, let stored = image.series?.thumbnail {
            let representation = NSBitmapImageRep(data: stored)
            let thumbnail = NSImage(size: representation?.size ?? .zero)
            if let representation { thumbnail.addRepresentation(representation) }
            return (thumbnail, pix ?? BrowserController.horos_emptyPreviewPix())
        }

        guard let pix else { return nil }
        let sopClassUID = image.series?.seriesSOPClassUID
        if DICOMSOPClass.isStructuredReport(sopClassUID) || DICOMSOPClass.isPDF(sopClassUID) {
            let icon = NSWorkspace.shared.icon(for: .plainText)
            let thumbnail = NSImage(size: NSSize(width: CGFloat(THUMBNAILSIZE), height: CGFloat(THUMBNAILSIZE)), flipped: false) { bounds in
                icon.draw(in: bounds, from: icon.alignmentRect, operation: .copy, fraction: 1.0)
                return true
            }
            return (thumbnail, pix)
        }
        let decoded = pix.generateThumbnailImage(withWW: image.series?.windowWidth?.floatValue ?? 0,
                                                 wl: pix.calibratedWindowLevel(forStoredLevel: image.series?.windowLevel?.floatValue ?? 0))
        pix.revert(false) // <- Kill the raw data
        guard let decoded, !pix.notAbleToLoadImage else { return (notFound, pix) }
        return (decoded, pix)
    }
}

/// The pictures of the viewers' series lists. One per series is kept scaled,
/// so that rebuilding a list does not decode and scale them again, and a
/// series with no stored thumbnail has one decoded off the main thread: an
/// image takes tenths of a second, which the list must not wait for.
@MainActor final class SeriesListThumbnails {
    static let shared = SeriesListThumbnails()

    private final class Picture {
        let stored: Data?, size: SeriesListPictureSize, inverted: Bool, image: NSImage
        init(stored: Data?, size: SeriesListPictureSize, inverted: Bool, image: NSImage) {
            self.stored = stored; self.size = size; self.inverted = inverted; self.image = image
        }
    }

    /// What is carried to the decoding queue and back. The series is only
    /// touched on the main actor.
    private struct Job: @unchecked Sendable {
        let id: NSManagedObjectID, series: DicomSeries, imageID: NSManagedObjectID?, database: DicomDatabase?, storing: Bool
    }

    private let pictures = NSCache<NSManagedObjectID, Picture>()
    /// Thumbnails made while the preference does not store them, or of a file that cannot be read.
    private let made = NSCache<NSManagedObjectID, NSImage>()
    private var pending = Set<NSManagedObjectID>()
    private let queue = DispatchQueue(label: "Series list thumbnails", qos: .userInitiated)

    init() {
        pictures.countLimit = 4000
        made.countLimit = 4000
    }

    private func scaled(_ image: NSImage, to size: SeriesListPictureSize) -> NSImage {
        if case .scaled(let factor) = size { return image.imageByScalingProportionallyUsingNSImage(Float(factor)) ?? image }
        return image
    }

    /// An empty picture of the size of a scaled thumbnail, or nil for none.
    func emptyPicture(size: SeriesListPictureSize) -> NSImage? {
        scaled(NSImage(size: NSSize(width: CGFloat(THUMBNAILSIZE), height: CGFloat(THUMBNAILSIZE))), to: size)
    }

    /// The series' picture, or nil while it has no thumbnail.
    func picture(of series: DicomSeries, size: SeriesListPictureSize, inverted: Bool) -> NSImage? {
        let stored = series.primitiveValue(forKey: "thumbnail") as? Data
        if let kept = pictures.object(forKey: series.objectID), kept.stored == stored, kept.size == size, kept.inverted == inverted {
            return kept.image
        }
        guard var image = stored.flatMap({ NSImage(data: $0) }) ?? made.object(forKey: series.objectID) else { return nil }
        if inverted { image = image.imageInverted() }
        let picture = scaled(image, to: size)
        pictures.setObject(Picture(stored: stored, size: size, inverted: inverted, image: picture), forKey: series.objectID)
        return picture
    }

    /// Decodes `image` for `series`, once however many lists ask, and sets
    /// the result on every list that shows the series.
    func make(series: DicomSeries, image: DicomImage?, database: DicomDatabase?, storing: Bool) {
        guard pending.insert(series.objectID).inserted else { return }
        let job = Job(id: series.objectID, series: series, imageID: image?.objectID, database: database, storing: storing)
        queue.async {
            let decoded = Self.decode(job)
            let result = LentImage(image: decoded)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { SeriesListThumbnails.shared.finish(job, result.image) }
            }
        }
    }

    private struct LentImage: @unchecked Sendable { let image: NSImage? }

    /// The series' first image, decoded on the queue through a context of its own.
    private nonisolated static func decode(_ job: Job) -> NSImage? {
        autoreleasepool {
            guard let imageID = job.imageID, let database = job.database?.privateQueueIndependentDatabase() as? DicomDatabase else { return nil }
            var result: NSImage?
            N2ManagedObjectContextPerformAndWait(database.managedObjectContext) {
                if let raised = HorosObjCException.caught({
                    guard let image = database.object(withID: imageID) as? DicomImage else { return }
                    let seriesID = (image.series?.id?.intValue).map { Int($0) } ?? 0
                    let pix = DCMPix(path: image.completePath(), 0, 0, nil, 0, seriesID, isBonjour: !database.isLocal(), imageObj: image)
                    pix?.checkLoad()
                    if let pix, !pix.notAbleToLoadImage { result = pix.generateThumbnailImage(withWW: 0, wl: 0) }
                }) {
                    _N2LogExceptionImpl(raised, true, "-[SeriesListThumbnails decode]")
                }
            }
            return result
        }
    }

    private func finish(_ job: Job, _ image: NSImage?) {
        pending.remove(job.id)
        guard job.series.managedObjectContext != nil, !job.series.isDeleted else { return }
        if let image, job.storing {
            job.series.thumbnail = BrowserController.produceJPEGThumbnail(image)
        } else if let shown = image ?? NSImage(named: "FileNotFound.tif") {
            made.setObject(shown, forKey: job.id)
        }
        for case let viewer as ViewerController in ViewerController.getDisplayed2DViewers() {
            viewer.seriesListPresenter.thumbnailMade(for: job.series)
        }
    }
}
