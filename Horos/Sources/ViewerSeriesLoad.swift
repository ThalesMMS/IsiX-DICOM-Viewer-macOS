//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import ObjectiveC

/// The load of one viewer's series: its start, its completion, its
/// cancellation and the viewer's close (#974).
///
/// One per viewer, made on first use. The pending load is the worker thread
/// the viewer's `loadingThread` instance variable names: that variable stays
/// where Objective-C and plugins read it (`-isEverythingLoaded`,
/// `-checkEverythingLoaded`, `+areLoadingViewers`, from any thread, under
/// `@synchronized`), and this is the only code that writes it. The worker is
/// `+[ViewerController loadImageData:]`: its request retains the pixel lists
/// and the volume buffers until every decode it started has finished, and it
/// delivers its completion to the main thread. Here, on the main thread, a
/// completion is accepted only for the load still pending on the same pixel
/// lists, and never after a cancellation or the close; an accepted load is
/// retired before the viewer announces it, so that a load started by an
/// observer of that announcement is not lost.
@MainActor
@objc(HorosViewerSeriesLoad)
public final class ViewerSeriesLoad: NSObject {
    @objc(HorosViewerSeriesLoadState)
    public enum State: Int {
        /// Nothing was asked yet.
        case idle
        /// A worker is decoding; its completion is awaited.
        case loading
        /// The last load was delivered to the viewer.
        case completed
        /// The last load was cancelled; its completion, if it comes, is refused.
        case cancelled
        /// The viewer is closing: no load starts and none is delivered.
        case closed
    }

    @objc public private(set) var state: State = .idle
    /// The viewer owns this load (an associated object) and outlives it; a weak
    /// reference would read nil in the viewer's -dealloc, which cancels through it.
    private unowned(unsafe) let viewer: ViewerController

    private init(viewer: ViewerController) {
        self.viewer = viewer
        super.init()
    }

    /// The viewer's load, made on first use and kept by the viewer.
    @objc(loadOfViewer:)
    public static func load(of viewer: ViewerController) -> ViewerSeriesLoad {
        if let existing = objc_getAssociatedObject(viewer, seriesLoadKey.key) as? ViewerSeriesLoad { return existing }
        let made = ViewerSeriesLoad(viewer: viewer)
        objc_setAssociatedObject(viewer, seriesLoadKey.key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// The pending worker, or nil.
    @objc public var pending: Thread? { viewer.horos_loadingThread }

    /// Starts decoding `pixLists` into `volumes`, replacing (and cancelling)
    /// any pending load. Refused once the viewer is closing. Returns whether
    /// a load started.
    @objc(startWithPixLists:volumes:computeOpeningContentBounds:)
    @discardableResult
    public func start(pixLists: NSArray, volumes: NSArray, computeOpeningContentBounds: Bool) -> Bool {
        guard state != .closed, !viewer.horos_windowWillClose else { return false }
        retire(cancelling: true)
        let request = NSMutableDictionary()
        request["volumeDataArray"] = volumes
        request["pixListArray"] = pixLists
        request["viewerController"] = viewer
        request["computeOpeningContentBounds"] = NSNumber(value: computeOpeningContentBounds)
        let worker = Thread(target: ViewerController.self, selector: NSSelectorFromString("loadImageData:"), object: request)
        synchronized(worker) {
            // loadingThread = worker, retained by the variable as before.
            viewer.horos_loadingThread = worker
            worker.start()
        }
        state = .loading
        return true
    }

    /// Whether `completion`, delivered by a worker, is the pending load's:
    /// its own thread, not cancelled, for the viewer's current pixel lists, the
    /// viewer neither cancelling nor closing. An accepted load is retired
    /// (without cancelling its successor); a refused one changes nothing.
    @objc(acceptCompletion:)
    public func accept(_ completion: NSDictionary?) -> Bool {
        guard state != .closed else { return false }
        let worker = completion?.object(forKey: "loadThread") as? Thread
        let lists = completion?.object(forKey: "pixListArray") as? NSArray
        // (lists.count != maxMovieIndex compares the short as an NSUInteger, as before.)
        guard !viewer.horos_windowWillClose, !viewer.horos_requestLoadingCancel, let worker,
              worker === viewer.horos_loadingThread, !worker.isCancelled,
              UInt(lists?.count ?? 0) == UInt(bitPattern: Int(viewer.horos_maxMovieIndex)) else { return false }
        for index in 0..<(lists?.count ?? 0) where (lists!.object(at: index) as AnyObject) !== viewer.horos_pixList(at: index) {
            return false
        }
        retire(cancelling: false)
        state = .completed
        return true
    }

    /// Cancels the pending load and forgets it: a series finalized, a viewer
    /// released.
    @objc public func cancel() {
        let wasLoading = pending != nil
        retire(cancelling: true)
        if wasLoading && state != .closed { state = .cancelled }
    }

    /// Asks the pending load to stop and refuses its completion, keeping the
    /// worker known until it leaves: the viewer is closing, or a viewer it
    /// fuses over is.
    @objc public func requestCancel() {
        viewer.horos_requestLoadingCancel = true
        let worker = viewer.horos_loadingThread
        synchronized(worker) { worker?.cancel() }
        if state == .loading { state = .cancelled }
    }

    /// The viewer closes: the pending load is cancelled, the worker is awaited
    /// until it has left - its request holds the pixels and volumes the
    /// viewer is about to release - and nothing starts or is delivered after.
    @objc public func close() {
        requestCancel()
        state = .closed
        while true {
            let worker = viewer.horos_loadingThread
            let executing = synchronized(worker) { worker?.isExecuting ?? false }
            if !executing { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        retire(cancelling: false)
    }

    /// Detaches the pending worker from the viewer, cancelling it or not. The
    /// variable's reference is given up by an autorelease, as it always was:
    /// code still synchronizing on the thread keeps it for the current pass.
    private func retire(cancelling: Bool) {
        guard let worker = viewer.horos_loadingThread else { return }
        synchronized(worker) {
            if cancelling { worker.cancel() }
            _ = Unmanaged.passUnretained(worker).autorelease()
            viewer.horos_assignLoading(nil)
        }
    }
}

/// @synchronized: nothing to lock for nil, as in Objective-C.
private func synchronized<T>(_ object: AnyObject?, _ body: () -> T) -> T {
    guard let object else { return body() }
    objc_sync_enter(object)
    defer { objc_sync_exit(object) }
    return body()
}

private let seriesLoadKey = IdentityToken()

extension ViewerController {
    /// This viewer's series load (#974).
    @objc(horosSeriesLoad)
    public var horosSeriesLoad: ViewerSeriesLoad { ViewerSeriesLoad.load(of: self) }
}
