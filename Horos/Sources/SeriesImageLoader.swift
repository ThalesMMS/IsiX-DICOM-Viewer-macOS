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

import Foundation
import Synchronization
import IsiXImaging

// The decoding of a 2D viewer's series: the viewer's ViewerSeriesLoad asks it
// with a SeriesLoadRequest and accepts its SeriesLoadResult on the main actor.
// SeriesImageLoader decodes the slices of its request in order, or on every
// processor when the series is compressed, and stops at the first slice after
// it is cancelled. It never reads the viewer: the request keeps the pixel lists
// and the volume storage, and only the result reaches the viewer.

/// What a viewer asks to be decoded: its pixel lists, one per movie frame, and
/// their volume storage, kept by the request until every decode it started has
/// finished, even when the viewer replaces its series or closes meanwhile.
///
/// `@unchecked Sendable`: the request hands the pixels to the loader alone.
/// DCMPix guards its decoding with a lock of its own, and the loader only asks
/// each slice to load and, once all are loaded, reads their frames.
struct SeriesLoadRequest: @unchecked Sendable {
    /// The viewer's pixel lists, the objects themselves: a result is accepted
    /// only while the viewer still shows them.
    let lists: [AnyObject]
    /// The slices of each list, in order.
    let frames: [[DCMPix]]
    /// The volume storage the slices point into.
    let volumes: [AnyObject]
    /// Whether the envelope of each series' content is measured for the fit
    /// asked at opening.
    let computeOpeningContentBounds: Bool
    /// What the load reports to, which the viewer's pending load answers from.
    let progress: SeriesLoadProgress
    /// The viewer's pending load, as the measure of the content bounds stops
    /// with it.
    let observedLoad: ObservedThread

    /// The request for the movie frames of `viewer`, on the main actor that
    /// owns its lists, reporting to `handle`. A frame without pixels or volume
    /// raises, as adding nil to the former request did.
    @MainActor init(viewer: ViewerController, computeOpeningContentBounds: Bool, handle: SeriesLoadHandle) {
        var lists: [AnyObject] = [], frames: [[DCMPix]] = [], volumes: [AnyObject] = []
        for movieIndex in 0..<Int(viewer.horos_maxMovieIndex) {
            guard let list = viewer.horos_pixList(at: movieIndex), let volume = viewer.horos_volumeData(at: movieIndex) else {
                NSException(name: .invalidArgumentException, reason: "*** -[__NSArrayM insertObject:atIndex:]: object cannot be nil",
                            userInfo: nil).raise()
                break
            }
            lists.append(list)
            frames.append(list.compactMap { $0 as? DCMPix })
            volumes.append(volume)
        }
        self.lists = lists
        self.frames = frames
        self.volumes = volumes
        self.computeOpeningContentBounds = computeOpeningContentBounds
        progress = handle.loadProgress
        observedLoad = ObservedThread(handle)
    }
}

/// A decoded request, and the envelope of each series' content by its index
/// in the request when it was asked for and measured.
struct SeriesLoadResult: Sendable {
    let request: SeriesLoadRequest
    let openingContentBounds: [Int: NSRect]?
}

/// What one series load reports, read from any thread: whether the loader is
/// decoding it, whether it was cancelled, whether the loader has left it, and
/// the share of its slices decoded.
final class SeriesLoadProgress: Sendable {
    private struct State {
        var executing = false
        var finished = false
        var cancelled = false
        var fraction: Float?
    }

    private let state = Mutex(State())

    var isExecuting: Bool { state.withLock { $0.executing } }
    var isFinished: Bool { state.withLock { $0.finished } }
    var isCancelled: Bool { state.withLock { $0.cancelled } }
    /// The share of the slices decoded, once the loader has reported one.
    var fraction: Float? { state.withLock { $0.fraction } }

    func cancel() {
        state.withLock { $0.cancelled = true }
    }

    /// The loader begins decoding.
    fileprivate func began() {
        state.withLock { $0.executing = true }
    }

    /// The share of the slices decoded so far.
    fileprivate func report(_ fraction: Float) {
        state.withLock { $0.fraction = fraction }
    }

    /// The loader has left: nothing it started still reads the request.
    fileprivate func ended() {
        state.withLock {
            $0.executing = false
            $0.finished = true
        }
    }
}

/// The handle of one series load: the object the viewer's `loadingThread`
/// names. What reads it asks what it asked the former load thread, from any
/// thread and under `@synchronized` on it: whether it is executing, cancelled
/// or finished, and its "loadingPercentage" (-isEverythingLoaded,
/// -checkEverythingLoaded, the window title and the plugins that read the
/// loadingThread key). It is a Thread for them alone and is never started:
/// SeriesImageLoader decodes the slices and reports to its loadProgress.
final class SeriesLoadHandle: Thread {
    let loadProgress = SeriesLoadProgress()

    override var isExecuting: Bool { loadProgress.isExecuting }
    override var isFinished: Bool { loadProgress.isFinished }
    override var isCancelled: Bool { loadProgress.isCancelled }

    override func cancel() {
        loadProgress.cancel()
    }

    /// The share of the slices decoded, under "loadingPercentage", once the
    /// loader has reported one; a dictionary of its own for each read.
    override var threadDictionary: NSMutableDictionary {
        .init(dictionary: loadProgress.fraction.map { ["loadingPercentage": NSNumber(value: $0)] } ?? [:])
    }

    override func start() {
        preconditionFailure("A series load handle is never started: SeriesImageLoader decodes the series")
    }
}

/// The slices of a compressed series taken by the decoders, and how many are decoded.
private final class DecodeCursor: Sendable {
    let next = Atomic<Int>(0)
    let decoded = Atomic<Int>(0)
}

/// The slices a compressed series hands to its decoders.
private struct DecodedSlices: @unchecked Sendable {
    let slices: [DCMPix]
}

/// The loader of one viewer's series, an actor on a serial queue of its own,
/// so that a long decode never holds a thread of Swift concurrency and a
/// viewer waiting on the main thread for its series (-checkEverythingLoaded)
/// waits for the queue alone. The viewer's ViewerSeriesLoad keeps one and
/// hands it each request; a request that replaces a cancelled one starts once
/// the slices the cancelled one was decoding are done.
actor SeriesImageLoader {

    private let queue = DispatchSerialQueue(label: "Load Image Data", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Decodes every slice of `request`, reporting to its progress, and
    /// measures the opening content bounds when the request asks for them.
    /// Nil once the load is cancelled. The progress is finished when this
    /// returns, whatever the outcome.
    func load(_ request: SeriesLoadRequest) -> SeriesLoadResult? {
        let start = Date.timeIntervalSinceReferenceDate
        NSLog("start loading")
        let result = autoreleasepool { decode(request) }
        request.progress.ended()
        if result != nil {
            NSLog("end loading: %f [s]", Date.timeIntervalSinceReferenceDate - start)
        }
        return result
    }

    private func decode(_ request: SeriesLoadRequest) -> SeriesLoadResult? {
        let progress = request.progress
        progress.began()
        if progress.isCancelled { return nil }

        var compressed: ObjCBool = false
        if let exception = HorosObjCException.caught({
            let firstPix = request.frames.first?.first
            DicomFile.isDICOMFile(firstPix?.srcFile, compressed: &compressed)
            if compressed.boolValue && BrowserController.isItCD(firstPix?.srcFile) {
                compressed = false
            }
        }) {
            _N2LogExceptionImpl(exception, false, "-[SeriesImageLoader load:]")
        }

        let slices = request.frames.flatMap { $0 }
        if compressed.boolValue {
            decodeConcurrently(slices, progress: progress)
        } else {
            decodeInOrder(slices, progress: progress)
        }
        if progress.isCancelled { return nil }
        progress.report(1)

        var bounds: [Int: NSRect]? = nil
        if request.computeOpeningContentBounds {
            bounds = OpeningContentBounds.measure(series: request.frames, loadThread: request.observedLoad)
            if progress.isCancelled { return nil }
        }
        return SeriesLoadResult(request: request, openingContentBounds: bounds)
    }

    /// One slice after the other, the share decoded reported at most every
    /// 0.3 s; the slice being decoded when the load is cancelled is the last.
    private func decodeInOrder(_ slices: [DCMPix], progress: SeriesLoadProgress) {
        var lastReport: TimeInterval = 0
        for (index, pix) in slices.enumerated() {
            if progress.isCancelled { return }
            pix.checkLoad()
            let now = Date.timeIntervalSinceReferenceDate
            if now - lastReport > 0.3 {
                progress.report(SeriesLoadRules.decodedShare(decoded: index + 1, of: slices.count))
                lastReport = now
            }
        }
    }

    /// Every slice on as many decoders as SeriesLoadRules gives for the
    /// processors, each taking the next slice not taken. A cancelled load
    /// takes no new slice, and this returns only when the slices being decoded
    /// are done: they write into the volume storage the request keeps.
    private func decodeConcurrently(_ slices: [DCMPix], progress: SeriesLoadProgress) {
        let decoders = SeriesLoadRules.compressedDecoders(processors: ProcessInfo.processInfo.processorCount)
        let cursor = DecodeCursor()
        let work = DecodedSlices(slices: slices)
        DispatchQueue.concurrentPerform(iterations: min(decoders, slices.count)) { _ in
            while true {
                let taken = cursor.next.wrappingAdd(1, ordering: .relaxed).oldValue
                guard taken < work.slices.count, !progress.isCancelled else { return }
                autoreleasepool { work.slices[taken].checkLoad() }
                let decoded = cursor.decoded.wrappingAdd(1, ordering: .relaxed).newValue
                progress.report(SeriesLoadRules.decodedShare(decoded: decoded, of: work.slices.count))
            }
        }
    }

    /// The envelope of each list of `lists` whose frames are loaded and share
    /// one geometry, keyed by the list itself (an NSValue of its address), as
    /// the viewer looks its series up; nil once `thread` is cancelled.
    nonisolated static func openingContentBounds(of lists: [AnyObject], thread: Thread?) -> [AnyHashable: Any]? {
        let frames = lists.map { ($0 as? [AnyObject] ?? []).compactMap { $0 as? DCMPix } }
        guard let found = OpeningContentBounds.measure(series: frames, loadThread: thread.map(ObservedThread.init)) else { return nil }
        return keyed(found, by: lists)
    }

    /// `bounds`, found by the index of each list, keyed by the list itself.
    nonisolated static func keyed(_ bounds: [Int: NSRect], by lists: [AnyObject]) -> [AnyHashable: Any] {
        Dictionary(uniqueKeysWithValues: bounds.map { (NSValue(nonretainedObject: lists[$0.key]) as AnyHashable, NSValue(rect: $0.value) as Any) })
    }
}
