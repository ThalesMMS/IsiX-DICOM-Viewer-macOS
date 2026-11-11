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
import CoreData
import ObjectiveC
import Synchronization
import IsiXImaging
import IsiXPreferences

// The series of a 2D viewer: its load and the change of the series it shows.
// ViewerSeriesLoad, one per viewer, starts the decoding of the viewer's pixel
// lists on its SeriesImageLoader and accepts the result on the main actor;
// ViewerLoadingState is the load as the other threads read it. The second part
// of the file gives the viewer a series (-changeImageData::::), releases the
// one it shows (-finalizeSeriesViewing), fits the images when they open and
// places the window. The viewer's selectors stay as façades in
// ViewerController+RetrieveAndView.swift.

/// The loading of the images and the life of the window as the loading and
/// post-processing threads see it, read from any thread: the pending load, a
/// cancel request, whether a wait for everything to load is running, whether
/// the window is closing, whether the series was post-processed.
final class ViewerLoadingState: Sendable {
    /// The pending load's handle as the lock keeps it. `@unchecked Sendable`:
    /// a Thread is not Sendable, but the handle answers from any thread
    /// through its SeriesLoadProgress, and nothing else of it is reached.
    private struct PendingLoad: @unchecked Sendable {
        let handle: SeriesLoadHandle
    }

    private struct Values {
        var load: PendingLoad?
        var requestLoadingCancel = false
        var checkEverythingLoaded = false
        var windowWillClose = false
        var postprocessed = false
    }

    private let values = Mutex(Values())

    /// The handle of the pending load, which ViewerSeriesLoad alone sets.
    var load: SeriesLoadHandle? {
        get { values.withLock { $0.load }?.handle }
        set {
            let pending = newValue.map(PendingLoad.init)
            values.withLock { $0.load = pending }
        }
    }

    /// The pending load as the readers of the former load thread see it.
    var loadingThread: Thread? { load }

    var requestLoadingCancel: Bool {
        get { values.withLock { $0.requestLoadingCancel } }
        set { values.withLock { $0.requestLoadingCancel = newValue } }
    }

    var checkEverythingLoaded: Bool {
        get { values.withLock { $0.checkEverythingLoaded } }
        set { values.withLock { $0.checkEverythingLoaded = newValue } }
    }

    var windowWillClose: Bool {
        get { values.withLock { $0.windowWillClose } }
        set { values.withLock { $0.windowWillClose = newValue } }
    }

    var postprocessed: Bool {
        get { values.withLock { $0.postprocessed } }
        set { values.withLock { $0.postprocessed = newValue } }
    }
}

extension ViewerController {
    nonisolated var horos_loadingThread: Thread? { loadingState.loadingThread }
    var horos_requestLoadingCancel: Bool {
        get { loadingState.requestLoadingCancel }
        set { loadingState.requestLoadingCancel = newValue }
    }
    var horos_checkEverythingLoadedFlag: Bool {
        get { loadingState.checkEverythingLoaded }
        set { loadingState.checkEverythingLoaded = newValue }
    }
    nonisolated var horos_windowWillClose: Bool {
        get { loadingState.windowWillClose }
        set { loadingState.windowWillClose = newValue }
    }
    nonisolated var horos_postprocessed: Bool {
        get { loadingState.postprocessed }
        set { loadingState.postprocessed = newValue }
    }
}

/// The load of one viewer's series: its start, its completion, its
/// cancellation and the viewer's close.
///
/// One per viewer, made on first use. The pending load is the handle the
/// viewer's loading state names: it stays where Objective-C and plugins read it
/// as the former load thread (`-isEverythingLoaded`, `-checkEverythingLoaded`,
/// `+areLoadingViewers`, the loadingThread key, from any thread), and this is
/// the only code that sets it. The decoding runs on the viewer's
/// SeriesImageLoader: its request keeps the pixel lists and the volume buffers
/// until every decode it started has finished, and its result comes back to
/// the main actor. A result is accepted only for the load still pending on the
/// same pixel lists, and never after a cancellation or the close; an accepted
/// load is retired before the viewer announces it, so that a load started by
/// an observer of that announcement is not lost.
@MainActor
@objc(HorosViewerSeriesLoad)
public final class ViewerSeriesLoad: NSObject {
    @objc(HorosViewerSeriesLoadState)
    public enum State: Int {
        /// Nothing was asked yet.
        case idle
        /// The series is being decoded; its result is awaited.
        case loading
        /// The last load was delivered to the viewer.
        case completed
        /// The last load was cancelled; its result, if it comes, is refused.
        case cancelled
        /// The viewer is closing: no load starts and none is delivered.
        case closed
    }

    @objc public private(set) var state: State = .idle
    /// The viewer owns this load (an associated object) and outlives it; a weak
    /// reference would read nil in the viewer's -dealloc, which cancels through it.
    private unowned(unsafe) let viewer: ViewerController
    private let preferences: any PreferenceStore
    private let loader = SeriesImageLoader()
    /// While a change of plane gives the viewer its new slices: the other
    /// windows on the volume keep the series being released and stay open.
    private var otherWindowsKeepPreviousSeries = false
    /// The series this window has shown, by their objects' ids.
    private var shownSeries: Set<NSManagedObjectID> = []

    private init(viewer: ViewerController, preferences: any PreferenceStore) {
        self.viewer = viewer
        self.preferences = preferences
        super.init()
    }

    /// The viewer's load, made on first use and kept by the viewer.
    @objc(loadOfViewer:)
    public static func load(of viewer: ViewerController) -> ViewerSeriesLoad {
        if let existing = objc_getAssociatedObject(viewer, seriesLoadKey.key) as? ViewerSeriesLoad { return existing }
        let made = ViewerSeriesLoad(viewer: viewer, preferences: viewer.sessionGraph.preferences)
        objc_setAssociatedObject(viewer, seriesLoadKey.key, made, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return made
    }

    /// The pending load, or nil.
    @objc public var pending: Thread? { viewer.horos_loadingThread }

    /// Starts decoding the viewer's series, every movie frame, replacing (and
    /// cancelling) any pending load. Refused once the viewer is closing.
    /// Returns whether a load started.
    @objc(start)
    @discardableResult
    public func start() -> Bool {
        guard state != .closed, !viewer.horos_windowWillClose else { return false }
        retire(cancelling: true)
        let handle = SeriesLoadHandle()
        let request = SeriesLoadRequest(viewer: viewer, computeOpeningContentBounds: preferences[ViewerPreferences.scaleToFitOnOpen],
                                        handle: handle)
        viewer.loadingState.load = handle
        state = .loading
        // The task keeps this load, not the viewer: a viewer freed meanwhile
        // has cancelled it, and its result is refused without reading the viewer.
        let loader = self.loader
        Task.detached { [self] in
            if let result = await loader.load(request) {
                await deliver(result)
            }
        }
        return true
    }

    /// Whether `result` is the pending load's: a load still awaited (the state
    /// is checked first, so that the result of a load cancelled by a viewer
    /// being freed reads nothing of it), its own progress, not cancelled, for
    /// the viewer's current pixel lists, the viewer neither cancelling nor
    /// closing. An accepted load is retired (without cancelling its
    /// successor); a refused one changes nothing.
    func accept(_ result: SeriesLoadResult) -> Bool {
        guard state == .loading else { return false }
        let progress = result.request.progress
        let lists = result.request.lists
        guard !viewer.horos_windowWillClose, !viewer.horos_requestLoadingCancel,
              progress === viewer.loadingState.load?.loadProgress, !progress.isCancelled,
              lists.count == Int(viewer.horos_maxMovieIndex) else { return false }
        for (index, list) in lists.enumerated() where list !== viewer.horos_pixList(at: index) {
            return false
        }
        retire(cancelling: false)
        state = .completed
        return true
    }

    /// The decoded series reaches the viewer, if it is still the one awaited:
    /// the measured content bounds, the original orientation, the mask
    /// subtraction of an XA series, the window and SUV of a PET series, the
    /// shutter, the title and the slice interval; then the fit asked at
    /// opening and OsirixViewerControllerDidLoadImagesNotification.
    func deliver(_ result: SeriesLoadResult) {
        guard accept(result) else { return }
        let viewer = self.viewer

        viewer.horos_openingContentBoundsByPixels = result.openingContentBounds.map { SeriesImageLoader.keyed($0, by: result.request.lists) }

        _ = viewer.computeOriginalOrientation()

        let firstPix = result.request.frames.first?.first

        // Modality dependent code, once the images are displayed in the 2D viewer.
        for frames in result.request.frames {
            for pix in frames {
                pix.maxValueOfSeries = 0
                pix.minValueOfSeries = 0
            }
        }

        // XA: the request holds the viewer's own movie lists (checked by
        // accept), which subtractionUnavailableReason reads, every one of them.
        viewer.horos_subCtrlMinMaxComputed = false
        viewer.horos_enableSubtraction = viewer.subtractionUnavailableReason() == nil
        viewer.enableSubtraction()

        // PET
        let modality = firstPix?.modalityString
        let windowLevel = WindowLevelSettings(preferences: preferences)
        if windowLevel.windowsAsPET(modality: modality) {
            let windowing = PETWindowing(mode: windowLevel.defaultPETWindowLevel, percentFrom: windowLevel.petWindowFrom,
                                         percentTo: windowLevel.petWindowTo, suvFrom: windowLevel.petWindowFromSUV,
                                         suvTo: windowLevel.petWindowToSUV)
            if windowing != .stored {
                viewer.horos_imageView?.updatePresentationStateFromSeries()
            }
        }
        if modality == "PT" && preferences[ViewerPreferences.convertPETtoSUVautomatically] {
            viewer.convertPETtoSUV()
            viewer.horos_imageView?.setStartWLWW()
        }

        if firstPix?.shutterEnabled ?? false {
            viewer.setShutterOnOffButton(NSNumber(value: true))
        }

        viewer.setWindowTitle(viewer)

        viewer.horos_originalOrientation = -1
        viewer.computeIntervalAsync()

        // Complete only a request that survived interaction/workspace changes.
        if viewer.horos_openingScaleToFitRequested {
            viewer.imageViewsState.openingScaleToFit.cancelAll()
            viewer.imageViewsState.openingScaleToFit.perform("finishOpeningScaleToFit", after: 0.1) { [weak viewer] in
                viewer?.finishOpeningScaleToFit()
            }
        }

        postViewerNotification(.OsirixViewerControllerDidLoadImages, viewer)
    }

    /// Cancels the pending load and forgets it: a series finalized, a viewer
    /// released.
    @objc public func cancel() {
        let wasLoading = pending != nil
        retire(cancelling: true)
        if wasLoading && state != .closed { state = .cancelled }
    }

    /// Asks the pending load to stop and refuses its result, keeping the load
    /// known until it ends: the viewer is closing, or a viewer it fuses over is.
    @objc public func requestCancel() {
        viewer.horos_requestLoadingCancel = true
        viewer.loadingState.load?.cancel()
        if state == .loading { state = .cancelled }
    }

    /// The viewer closes: the pending load is cancelled, and awaited until the
    /// loader has left it - its request holds the pixels and volumes the
    /// viewer is about to release - and nothing starts or is delivered after.
    @objc public func close() {
        requestCancel()
        state = .closed
        while true {
            let load = viewer.horos_loadingThread
            // isFinished, not isExecuting: a load that has just been started is
            // not executing yet, and the loader had not left it.
            if load?.isFinished ?? true { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        retire(cancelling: false)
    }

    /// Detaches the pending load from the viewer, cancelling it or not.
    private func retire(cancelling: Bool) {
        guard let load = viewer.loadingState.load else { return }
        if cancelling { load.cancel() }
        viewer.loadingState.load = nil
    }

    /// Records that this window shows `series`, and answers whether it had
    /// shown it before.
    func recordSeriesShown(_ series: NSManagedObjectID?) -> Bool {
        guard let series else { return false }
        return !shownSeries.insert(series).inserted
    }
}

private let seriesLoadKey = IdentityToken()

extension ViewerController {
    /// This viewer's series load.
    @objc(horosSeriesLoad)
    public var horosSeriesLoad: ViewerSeriesLoad { ViewerSeriesLoad.load(of: self) }
}

// MARK: - The series shown

/// The MULTIPLESCREENS preference: the screen a viewer opens on (0 the main
/// one, 1 the second one, 2 all of them, which opens on the main one).
private let multipleScreens = PreferenceKey<Int>("MULTIPLESCREENS")
/// Small images are resampled when they open (ResampleData), when their
/// smaller side is at most ResampleDataIfSmallerOrEqualValue, to ResampleDataValue.
private let resamplesSmallImages = PreferenceKey<Bool>("ResampleData")
private let resamplingThreshold = PreferenceKey<Int>("ResampleDataIfSmallerOrEqualValue")
private let resamplingDestination = PreferenceKey<Float>("ResampleDataValue")

/// `[a isEqualToString: b]`: NO when either is nil.
private func sameText(_ a: String?, _ b: String?) -> Bool {
    guard let a, let b else { return false }
    return (a as NSString).isEqual(to: b)
}

/// `[string compare: other options: options]`, sent as Objective-C sent it: a
/// nil receiver answers NSOrderedSame (0), and a nil argument reaches the
/// method as nil.
private func objcCompare(_ string: String?, _ other: String?, _ options: NSString.CompareOptions) -> ComparisonResult {
    guard let string = string as NSString? else { return .orderedSame }
    let selector = #selector(NSString.compare(_:options:))
    typealias Compare = @convention(c) (NSString, Selector, NSString?, UInt) -> Int
    let compare = unsafeBitCast(string.method(for: selector), to: Compare.self)
    return ComparisonResult(rawValue: compare(string, selector, other as NSString?, options.rawValue)) ?? .orderedSame
}

/// The patient comparison of the former code: case, diacritics and width ignored.
private let patientComparison: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

/// `(int) x` of a double on arm64: NaN is 0, out of range saturates.
private func cInt32(_ x: Double) -> Int32 {
    if x.isNaN { return 0 }
    if x >= 2147483647.0 { return Int32.max }
    if x <= -2147483648.0 { return Int32.min }
    return Int32(x)
}

/// The series a viewer is given: its pixels, its images and the volume the
/// pixels point into, the objects themselves, which the viewer keeps.
struct GivenSeries {
    let pixels, files: NSMutableArray?
    let volume: NSData?
}

/// An empty list of the viewer's per-image lists (its ROIs, their copies).
private func emptyList() -> NSMutableArray { NSMutableArray(capacity: 0) }

/// A value stored in one of the viewer's manually retained slots, which the
/// former code retained itself before storing it.
private func retainedForSlot<T: AnyObject>(_ object: T?) -> T? {
    if let object { _ = Unmanaged.passUnretained(object).retain() }
    return object
}

/// `[view setPixels: pixels files: files rois: rois firstImage: … level: … reset: …]`
/// with the file list object itself: the files Swift imports as an array
/// would hand the view a copy instead of the viewer's live fileList.
private func setPixels(of view: DCMView?, _ pixels: AnyObject?, files: AnyObject?, rois: AnyObject?, reset: Bool) {
    guard let view else { return }
    let selector = NSSelectorFromString("setPixels:files:rois:firstImage:level:reset:")
    typealias Send = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?, Int, CChar, Bool) -> Void
    unsafeBitCast(view.method(for: selector), to: Send.self)(view, selector, pixels, files, rois, 0, CChar(UInt8(ascii: "i")), reset)
}

extension ViewerSeriesLoad {

    private var graph: ViewerSessionGraph { viewer.sessionGraph }

    /// The first image of the viewer's list of movie frame `index`.
    private func firstImage(_ index: Int = 0) -> DicomImage? {
        viewer.horos_fileList(at: index)?.firstObject as? DicomImage
    }

    /// The slice locations of the viewer's first movie frame, in mm.
    private func sliceLocations() -> [Float] {
        (viewer.horos_fileList(at: 0) ?? []).map { (($0 as? DicomImage)?.sliceLocation?.floatValue) ?? 0 }
    }

    /// Shows `index` of the viewer's first list, read upside down when the
    /// series was flipped, and moves the slider to it.
    private func showSlice(_ index: Int, flipped: Bool) {
        let count = viewer.horos_fileList(at: 0)?.count ?? 0
        viewer.horos_imageView?.setIndex(flipped ? SeriesLoadRules.flippedIndex(index, count: count) : index)
    }

    // MARK: Changing the series

    /// Whether other post-processing windows (MPR, volume rendering…) use the
    /// volume of the viewer's series. It cannot be released under them, so
    /// the series is not replaced in this window while they are open, and
    /// nothing that rewrites the volume in place may run either: they would
    /// show the new pixels with the geometry of the old ones.
    var volumeIsUsedByOtherWindows: Bool {
        var minWindows = 1
        if viewer.fullScreenON() { minWindows += 1 }
        return (graph.processGraph.appController?.FindRelatedViewers(viewer.horos_pixList(at: 0))?.count ?? 0) > minWindows
    }

    /// The windows that show the viewer's series with it: the 3D windows
    /// opened on its volume.
    private var otherWindowsOnVolume: [AnyObject] {
        let related = graph.processGraph.appController?.FindRelatedViewers(viewer.horos_pixList(at: 0)) ?? []
        return related.map { $0 as AnyObject }.filter { $0 !== viewer }
    }

    /// Runs `change`, which gives the viewer another series in place (a
    /// change of plane), letting the other windows on its volume keep the
    /// series it releases instead of refusing the change because of them.
    func keepingPreviousSeriesForOtherWindows(_ change: () -> Void) {
        let before = otherWindowsKeepPreviousSeries
        otherWindowsKeepPreviousSeries = true
        defer { otherWindowsKeepPreviousSeries = before }
        change()
    }

    /// Gives the other windows on the volume a hold on every time point of
    /// the series, which the viewer is about to release: they do not retain
    /// what they show. Returns those windows.
    private func holdSeriesForOtherWindows() -> [AnyObject] {
        let windows = otherWindowsOnVolume
        guard !windows.isEmpty else { return [] }
        var series: [AnyObject] = []
        for movie in 0..<max(Int(viewer.horos_maxMovieIndex), 0) {
            if let pixels = viewer.horos_pixList(at: movie) { series.append(pixels) }
            if let files = viewer.horos_fileList(at: movie) { series.append(files) }
            if let rois = viewer.horos_roiList(at: movie) { series.append(rois) }
            if let volume = viewer.horos_volumeData(at: movie) { series.append(volume) }
        }
        for window in windows {
            PreviousSeriesHold.hold(series, releasedBy: viewer, for: window)
        }
        return windows
    }

    /// -changeImageData::::. The viewer shows the pixels `f`, the images `d`
    /// and the volume `v` instead of its series, unless other post-processing
    /// windows use its volume (`newViewerWindow` when the window was just
    /// made for them). The new series keeps the position (mm) of a series of
    /// the same study and orientation, takes the colour tables, the tiling and
    /// the fit its study and modality give, and announces the change.
    func show(_ given: GivenSeries, newViewerWindow: Bool) {
        let viewer = self.viewer
        let f = given.pixels, d = given.files
        if viewer.horos_windowWillClose { return }
        cancelOpeningScaleToFit()

        OSIEnvironment.shared()?.viewerControllerWillChangeData(viewer)

        graph.processGraph.appController?.windowArranger.tileNowIfScheduled()

        if viewer.horos_curMovieIndex != 0 {
            viewer.setMovieIndex(0)
        }

        let previousColumns = viewer.horos_imageView?.columns ?? 0, previousRows = viewer.horos_imageView?.rows ?? 0
        let previousFusion = Int32(truncatingIfNeeded: viewer.horos_popFusion?.selectedTag() ?? 0)
        let previousFusionActivated = Int32(truncatingIfNeeded: viewer.horos_activatedFusion?.state.rawValue ?? 0)

        let previous = Previous(patientUID: firstImage()?.series?.study?.patientUID,
                                studyInstanceUID: firstImage()?.series?.study?.studyInstanceUID,
                                image: viewer.horos_imageView?.imageObj(),
                                curImage: Int32(viewer.horos_imageView?.curImage ?? 0),
                                wasFlipped: viewer.horos_imageView?.flippedData ?? false)

        objc_sync_enter(viewer)
        viewer.horos_statusValueToApply = -1

        if let e = HorosObjCException.caught({
            var orientation = (equal: true, newIsSet: false)
            var previousLocation: Float = 0

            viewer.horos_nonVolumicDataWarningDisplayed = true

            if previousColumns != 1 || previousRows != 1 {
                viewer.horos_imageView = viewer.horos_seriesView?.imageViews()?.firstObject as? DCMView
                _ = viewer.horos_imageView?.becomeFirstResponder()

                viewer.setImageRows(1, columns: 1)
            }

            // [imageView mouseUp: [NSApp currentEvent]]: the current event may be nil.
            _ = viewer.horos_imageView?.perform(NSSelectorFromString("mouseUp:"), with: NSApplication.shared.currentEvent)

            if (viewer.horos_pixList(at: 0)?.count ?? 0) != 0 && (d?.count ?? 0) != 0 {
                viewer.selectFirstTilingView()
                viewer.horos_imageView?.updateTilingViews()

                var previousOrientation = [Float](repeating: 0, count: 9), newOrientation = [Float](repeating: 0, count: 9)
                (viewer.horos_pixList(at: 0)?.firstObject as? DCMPix)?.orientation(&previousOrientation)
                (f?.firstObject as? DCMPix)?.orientation(&newOrientation)
                orientation = SeriesLoadRules.compareOrientations(previousOrientation, newOrientation)

                let syncsBetweenStudies = sameText(previous.studyInstanceUID, (d?.firstObject as? DicomImage)?.series?.study?.studyInstanceUID)
                    && ViewerController.horos_syncButtonBehaviorIsBetweenStudies() && ViewerController.horos_SYNCSERIES()
                if !syncsBetweenStudies {
                    viewer.turnOffSyncSeriesBetweenStudies(viewer)
                }

                previousLocation = viewer.horos_imageView?.imageObj()?.sliceLocation?.floatValue ?? 0
            }
            // Check if another post-processing viewer is open : we CANNOT release the fVolumePtr -> OsiriX WILL crash

            if !newViewerWindow && volumeIsUsedByOtherWindows && !otherWindowsKeepPreviousSeries {
                NSSound.beep()
                NSLog("changeImageData not possible with other post-processing windows opened")
            } else {
                replace(given, previous: previous, orientation: orientation, previousLocation: previousLocation,
                        previousColumns: previousColumns, previousRows: previousRows,
                        previousFusion: previousFusion, previousFusionActivated: previousFusionActivated)
            }

            postViewerNotification(.OsirixViewerDidChange, viewer)

            viewer.willChangeValue(forKey: "KeyImageCounter")
            viewer.didChangeValue(forKey: "KeyImageCounter")

            viewer.horos_imageView?.computeColor()

            if viewer.horos_exportDCM != nil {
                viewer.horos_exportDCM = nil //We want new UNIQUE seriesInstanceUID & studyInstanceUID
            }
        }) {
            _N2LogExceptionImpl(e, true, "-[ViewerController changeImageData::::]")
        }
        objc_sync_exit(viewer)

        for other in graph.registry.displayedViewers where other !== viewer {
            other.propagateSettings()
        }

        OSIEnvironment.shared()?.viewerControllerDidChangeData(viewer)
    }

    /// What the viewer showed before its series changed.
    private struct Previous {
        let patientUID: String?
        let studyInstanceUID: String?
        let image: DicomImage?
        let curImage: Int32
        let wasFlipped: Bool
    }

    /// The viewer's series is released and the new one given to its views.
    private func replace(_ given: GivenSeries, previous: Previous,
                         orientation: (equal: Bool, newIsSet: Bool), previousLocation: Float,
                         previousColumns: Int, previousRows: Int, previousFusion: Int32, previousFusionActivated: Int32) {
        let viewer = self.viewer
        let f = given.pixels, v = given.volume
        var d = given.files
        viewer.horos_imageView?.drawing = false

        postViewerNotification(.OsirixViewerWillChange, viewer)

        viewer.activateBlending(nil)
        viewer.clear8bitRepresentations()
        viewer.horos_shutterOnOff?.state = .off

        viewer.setFusionMode(0)

        viewer.horos_imageView?.setIndex(0)

        var closeInfo: [AnyHashable: Any] = [:]
        if let newStudyID = (d?.firstObject as? DicomImage)?.series?.study?.objectID { closeInfo["newStudyID"] = newStudyID }
        // The 3D windows on the volume close on this announcement, unless a
        // change of plane leaves them the series: then they hold it and stay.
        // Those that already hold a former series of this viewer read the
        // same entry, which is there for every change of plane.
        if otherWindowsKeepPreviousSeries {
            closeInfo[PreviousSeriesHold.keptWindowsKey] = holdSeriesForOtherWindows()
        }
        postViewerNotification(.OsirixCloseViewer, viewer, closeInfo)

        viewer.horos_windowWillClose = true

        viewer.setUpdateTilingViewsValue(true)

        if (viewer.horos_subCtrlOnOff?.state.rawValue ?? 0) != 0 { viewer.horos_imageView?.setWLWW(0, 0) }
        viewer.check(viewer.horos_subCtrlView, false)

        if viewer.horos_currentOrientationTool != viewer.horos_originalOrientation && viewer.horos_originalOrientation != -1 {
            viewer.horos_imageView?.xFlipped = false
            viewer.horos_imageView?.yFlipped = false
            viewer.horos_imageView?.rotation = 0
        }

        viewer.horos_orientationMatrix?.isEnabled = false

        var sameSeries = false
        if (d?.count ?? 0) > 0, let previousSeries = firstImage()?.series?.objectID,
           previousSeries.isEqual(to: (d?.firstObject as? DicomImage)?.series?.objectID) {
            sameSeries = true
        }

        // Release previous data
        finalize(viewerStays: true)

        N2ManagedObjectContextPerformAndWait(graph.processGraph.browserDatabase?.managedObjectContext) {
            if let e = HorosObjCException.caught({
                viewer.horos_orientationMatrix?.selectCell(withTag: 0)

                viewer.horos_curCLUTMenu = NSLocalizedString("No CLUT", comment: "")
                viewer.horos_curConvMenu = NSLocalizedString("No Filter", comment: "")
                viewer.horos_curWLWWMenu = NSLocalizedString("Default WL & WW", comment: "")

                viewer.horos_curMovieIndex = 0
                viewer.horos_maxMovieIndex = 1
                viewer.horos_subCtrlMaskID = -2
                viewer.horos_assignRegisteredViewer(nil)
                viewer.horos_resampleRatio = 1.0

                viewer.horos_assignVolumeData(retainedForSlot(v), at: 0)
                viewer.horos_sendDidAllocateVolumeDataNotification(forMovieIndex: 0)

                viewer.horos_direction = 1

                viewer.horos_assignPixList(retainedForSlot(f), at: 0)

                // Prepare pixList for image thick slab
                if let pixels = viewer.horos_pixList(at: 0) {
                    for index in 0..<pixels.count {
                        if let pix = pixels.object(at: index) as? DCMPix { viewerSetArrayPix(pix, pixels, index) }
                    }
                }

                if (d?.count ?? 0) == 0 { d = nil }
                viewer.horos_assignFileList(retainedForSlot(d), at: 0)

                if let e = HorosObjCException.caught({
                    // Prepare roiList
                    viewer.horos_assignRoiList(retainedForSlot(emptyList()), at: 0)
                    viewer.horos_assignCopyRoiList(retainedForSlot(emptyList()), at: 0)
                    for _ in 0..<(viewer.horos_pixList(at: 0)?.count ?? 0) {
                        viewer.horos_roiList(at: 0)?.add(emptyList())
                        viewer.horos_copyRoiList(at: 0)?.add(NSData())
                    }
                    viewer.loadROI(0)

                    setPixels(of: viewer.horos_imageView, viewer.horos_pixList(at: 0), files: viewer.horos_fileList(at: 0),
                              rois: viewer.horos_roiList(at: 0), reset: !sameSeries)

                    viewer.horos_imageView?.setIndexWithReset(0, true)
                }) {
                    NSLog("Exception change image data: %@", e)
                }

                showControls(sameSeries: sameSeries)

                if objcCompare(previous.patientUID, firstImage()?.series?.study?.patientUID, patientComparison) != .orderedSame {
                    viewer.buildMatrixPreview()
                }
                viewer.showCurrentThumbnail(viewer)

                if preferences[ViewerPreferences.onlyDisplayImagesOfSamePatient] {
                    closeViewersOfOtherPatients()
                }

                keepPosition(previous: previous, sameSeries: sameSeries, orientation: orientation, previousLocation: previousLocation)

                // Is it only key images?
                let images = viewer.horos_fileList(at: 0) ?? []
                let keyFlags = images.map { (($0 as? DicomImage)?.isKeyImage()?.boolValue) ?? false }
                viewer.horos_displayOnlyKeyImages = images.count != 0
                    && SeriesLoadRules.showsOnlyKeyImages(listed: keyFlags, seriesCount: firstImage()?.series?.images?.count ?? 0,
                                                          postprocessed: viewer.horos_postprocessed)
                viewer.horos_keyImagePopUpButton?.selectItem(at: viewer.horos_displayOnlyKeyImages ? 1 : 0)

                viewer.horos_windowWillClose = false

                viewer.setPostprocessed(false)

                viewer.setSyncButtonBehavior(viewer)

                if viewer.window?.isVisible ?? false {
                    viewer.horos_imageView?.becomeMainWindow()	// This will send the image sync order !
                }

                viewer.setUpdateTilingViewsValue(false)

                viewer.selectFirstTilingView()
                viewer.horos_imageView?.updateTilingViews()

                if previousFusionActivated != 0 {
                    viewer.setFusionMode(Int(previousFusion))

                    _ = viewer.horos_popFusion?.selectItem(withTag: Int(previousFusion))

                    viewer.horos_imageView?.sendSyncMessage(0)
                }

                if preferences[ViewerPreferences.automaticFusion] {
                    viewer.blendWindows(nil)
                }

                viewer.refreshMenus()

                viewer.horos_postCurrentImageUpdate()

                if previousColumns != 1 || previousRows != 1 {
                    viewer.horos_imageView = viewer.horos_seriesView?.imageViews()?.firstObject as? DCMView
                    _ = viewer.horos_imageView?.becomeFirstResponder()
                }

                viewer.setCurWLWWMenu(DCMView.findWLWWPreset(viewer.horos_imageView?.curWL ?? 0, viewer.horos_imageView?.curWW ?? 0, viewer.horos_imageView?.curDCM))

                viewer.horos_nonVolumicDataWarningDisplayed = false

                for other in graph.registry.displayedViewers {
                    other.seriesListPresenter.build(showSelected: false, selectionOnly: true)
                }

                let subtractionOffset = viewer.horos_imageView?.curDCM?.subPixOffset ?? NSPoint.zero
                viewer.offsetMatrixSetting((viewer.threeTestsFivePosibilities(cInt32(Double(subtractionOffset.y))) &* 5)
                                           &+ viewer.threeTestsFivePosibilities(cInt32(Double(subtractionOffset.x))))

                viewer.horos_subCtrlSum?.floatValue = 1
                viewer.horos_subCtrlPercent?.floatValue = 1

                viewer.horos_imageView?.drawing = true
                viewer.horos_imageView?.needsDisplay = true

                applyTiling()

                if !sameSeries {
                    // A series this window showed before comes back with the
                    // zoom and pan saved when it was left, restored above:
                    // fitting it again undid them a moment after they appeared.
                    let series = firstImage()?.series?.objectID
                    if !recordSeriesShown(series) {
                        requestOpeningScaleToFit()
                    }
                }
            }) {
                NSLog("***** changeImageData exception : %@", e)
                viewer.window?.close()
            }
        }

        viewer.horos_imageView?.computeColor()

        viewer.redrawToolbar()
    }

    /// The window title, the sliders, the movie controls, the colour and
    /// opacity tables of the series' modality, its status and comment, and the
    /// browser's selection, for the series just given.
    private func showControls(sameSeries: Bool) {
        let viewer = self.viewer
        let pic = viewer.horos_imageView?.curDCM

        viewer.setWindowTitle(viewer)

        let slices = viewer.horos_pixList(at: 0)?.count ?? 0
        viewer.horos_slider?.maxValue = Double(slices - 1)
        viewer.horos_slider?.numberOfTickMarks = slices
        viewer.adjustSlider()

        if (viewer.horos_fileList(at: 0)?.count ?? 0) == 1 {
            viewer.horos_speedSlider?.isEnabled = false
            viewer.horos_slider?.isEnabled = false
        } else {
            if (pic?.cineRate() ?? 0) != 0 {
                viewer.horos_speedSlider?.floatValue = pic?.cineRate() ?? 0
            } else if preferences[ViewerPreferences.defaultFrameRate] != 0 {
                viewer.horos_speedSlider?.floatValue = preferences[ViewerPreferences.defaultFrameRate]
            }

            viewer.horos_speedSlider?.isEnabled = true
            viewer.horos_slider?.isEnabled = true
        }

        viewer.horos_subCtrlOnOff?.state = .off
        viewer.horos_convPopup?.selectItem(at: 0)
        let stackThickness = Int32(truncatingIfNeeded: preferences[ViewerPreferences.stackThickness])
        viewer.horos_stacksFusion?.intValue = stackThickness
        viewer.horos_sliderFusion?.intValue = stackThickness
        viewer.horos_sliderFusion?.isEnabled = false
        viewer.horos_activatedFusion?.state = .off

        // maxMovieIndex was just reset to 1: this series has one
        // time. A movie left running here kept firing behind a
        // control switched off and still titled "Stop", so the
        // images went on changing and the button that would stop
        // them could not be pressed.
        if FourDSeriesGuard.playControlApplies(timeCount: Int(viewer.horos_maxMovieIndex)) == false {
            viewer.movieStop(viewer)
        }

        viewer.horos_movieRateSlider?.isEnabled = false
        viewer.horos_moviePosSlider?.isEnabled = false
        viewer.horos_moviePlayStop?.isEnabled = false

        if preferences[ViewerPreferences.defaultMovieRate] != 0 {
            viewer.horos_movieRateSlider?.floatValue = preferences[ViewerPreferences.defaultMovieRate]
            viewer.horos_movieTextSlide?.stringValue = String(format: NSLocalizedString("%0.0f im/s", comment: "im/s = images per second"), Double(viewer.movieRate()))
        }

        viewer.horos_speedText?.stringValue = String(format: NSLocalizedString("%0.1f im/s", comment: "im/s = images per second"), Double(viewer.frameRate() * viewer.horos_direction))

        viewer.horos_seriesView?.setPixels(viewer.horos_pixList(at: 0), files: viewer.horos_fileList(at: 0), rois: viewer.horos_roiList(at: 0),
                                           firstImage: 0, level: CChar(UInt8(ascii: "i")), reset: !sameSeries)

        applyOpeningTables()

        let movieIndex = Int(viewer.horos_curMovieIndex)
        let files = viewer.horos_fileList(at: movieIndex)
        var curImage = Int32(viewer.horos_imageView?.curImage ?? 0)
        // int compared with an NSUInteger count: as the unsigned value.
        if UInt(bitPattern: Int(curImage)) >= UInt(files?.count ?? 0) {
            curImage = 0
        }
        let shown = (files?.count ?? 0) > Int(curImage) ? files?.object(at: Int(curImage)) as? DicomImage : nil

        StudyStates.select(shown?.series?.study?.stateText?.intValue ?? 0, in: viewer.horos_StatusPopup)

        var comment = shown?.series?.comment
        if comment?.isEmpty ?? true {
            comment = shown?.series?.study?.comment
        }
        viewer.horos_CommentsField?.title = comment.flatMap { $0.isEmpty ? nil : $0 } ?? NSLocalizedString("Add a comment", comment: "")

        let firstPath = ((files?.firstObject as? DicomImage)?.completePath() as NSString?)?.lastPathComponent
        if !sameText(firstPath, "Empty.tif") {
            _ = graph.processGraph.currentBrowser?.findAndSelectFile(nil, image: shown, shouldExpand: false)
        }
    }

    /// The colour and opacity tables, and the 12-bit display, a grey series
    /// of the viewer's modality opens with; an RGB series takes neither table.
    private func applyOpeningTables() {
        let viewer = self.viewer
        let modality = viewer.modality()
        let isRGB = (viewer.horos_pixList(at: 0)?.firstObject as? DCMPix)?.isRGB ?? false

        let colour = SeriesLoadRules.colourTable(modality: modality, isRGB: isRGB, nmAsPET: preferences[ViewerPreferences.petCLUTForNM],
                                                 petMode: preferences[ViewerPreferences.petCLUTMode],
                                                 petDefault: preferences[ViewerPreferences.petDefaultCLUT])
        switch colour {
        case .plain: viewer.applyCLUTString(NSLocalizedString("No CLUT", comment: ""))
        case .named(let name): viewer.applyCLUTString(name)
        }

        let opacity = SeriesLoadRules.opacityTable(modality: modality, isRGB: isRGB, nmAsPET: preferences[ViewerPreferences.opacityTableNM],
                                                   petOpacity: preferences[ViewerPreferences.petOpacityTable],
                                                   petDefault: preferences[ViewerPreferences.petDefaultOpacityTable])
        switch opacity {
        case .plain: viewer.applyOpacityString(NSLocalizedString("Linear Table", comment: ""))
        case .named(let name): viewer.applyOpacityString(name)
        }

        if SeriesLoadRules.opensTwelveBit(modality: modality, isRGB: isRGB, automatic: preferences[ViewerPreferences.automatic12BitTotoku],
                                          displayCanShow: { AppController.canDisplay12Bit() }) {
            viewer.horos_imageView?.setIsLUT12Bit(true)
            viewer.horos_display12bitToolbarItemMatrix?.selectCell(withTag: 0)
        }
    }

    /// The viewers of another patient close, when only one patient's images
    /// are displayed at a time.
    private func closeViewersOfOtherPatients() {
        let current = firstImage()?.series?.study
        for other in graph.registry.displayedViewers {
            let otherStudy = (other.fileList()?.firstObject as? DicomImage)?.series?.study
            if objcCompare(current?.patientUID, otherStudy?.patientUID, patientComparison) != .orderedSame
                && !sameText(current?.patientID, otherStudy?.patientID) {
                other.window?.close()
            }
        }
    }

    /// The image the new series opens on. The same series again opens on
    /// the image shown before; another series of the same study and
    /// orientation, at the same position (mm) when it covers it, from the
    /// previous series or from a parallel viewer of the study, and keeps the
    /// fusion of a CT then. A series of another study cancels the fusion.
    private func keepPosition(previous: Previous, sameSeries: Bool, orientation: (equal: Bool, newIsSet: Bool), previousLocation: Float) {
        let viewer = self.viewer
        guard sameText(previous.studyInstanceUID, firstImage()?.series?.study?.studyInstanceUID) else {
            if viewer.horos_blending != nil { viewer.activateBlending(nil) }
            return
        }
        if sameSeries {
            // Can we find the same DicomImage?
            if let image = previous.image {
                let index = viewer.horos_fileList(at: 0)?.index(of: image) ?? 0
                if index != NSNotFound { showSlice(index, flipped: previous.wasFlipped) }
            }
            return
        }

        var keepFusion = false
        if orientation.equal && orientation.newIsSet {
            let locations = sliceLocations()
            if locations.first == locations.last {
                viewer.horos_imageView?.setIndex(Int(truncatingIfNeeded: previous.curImage))
                viewer.adjustSlider()
                keepFusion = true
            } else if let index = SeriesLoadRules.nearestSlice(to: previousLocation, sliceLocations: locations) {
                showSlice(index, flipped: previous.wasFlipped)
                viewer.adjustSlider()
                keepFusion = true
            }
        } else if orientation.newIsSet { // Try to find another viewer, of the same study, with same orientation
            for other in graph.registry.displayedViewers {
                if other !== viewer && other.isDataVolumicIn4D(false,
                                                               checkEverythingLoaded: SeriesReplaceLoadPolicy.peerVolumicProbeWaitsForLoad,
                                                               tryToCorrect: SeriesReplaceLoadPolicy.peerVolumicProbeCorrectsPeer)
                    && sameText(other.studyInstanceUID(), viewer.studyInstanceUID()) && viewer.parallel(toViewer: other) && (other.imageView()?.curImage ?? 0) != 0 {
                    let location = other.currentImage()?.sliceLocation?.floatValue ?? 0
                    if let index = SeriesLoadRules.nearestSlice(to: location, sliceLocations: sliceLocations()) {
                        showSlice(index, flipped: previous.wasFlipped)
                        viewer.adjustSlider()
                        keepFusion = true
                        break
                    }
                }
            }
        }

        if keepFusion && !sameText(viewer.modality(), "CT") { keepFusion = false }

        if !keepFusion && viewer.horos_blending != nil {
            viewer.activateBlending(nil)
        }
    }

    /// The tiling of the images: the hanging protocol of the study's modality
    /// and description, or what the study's saved windows state gives its
    /// series; and whether the views copy their settings within the series.
    private func applyTiling() {
        let viewer = self.viewer
        let study = viewer.currentStudy()
        let series = viewer.currentSeries()

        // default protocol
        let layouts = WindowLayoutManager.shared()
        layouts?.setCurrentHangingProtocolForModality(study?.modality, description: study?.studyName)

        var newColumns = layouts?.imagesColumns() ?? 0
        var newRows = layouts?.imagesRows() ?? 0

        // is there a windows state?
        if let state = study?.windowsState, preferences[ViewerPreferences.automaticWorkspaceLoad] {
            let viewers = (try? PropertyListSerialization.propertyList(from: state, options: [], format: nil)) as? [Any] ?? []
            if let saved = SeriesLoadRules.savedTiling(in: viewers, studyUID: study?.studyInstanceUID, seriesUID: series?.seriesInstanceUID) {
                newRows = saved.rows
                newColumns = saved.columns
            }
        }

        let propagates = !DCMView.noPropagateSettingsInSeries(forModality: viewer.modality())
        for case let view as DCMView in viewer.horos_seriesView?.imageViews() ?? [] where view.copysettingsinseries != propagates {
            view.copysettingsinseries = propagates
        }

        if newRows != 1 || newColumns != 1 {
            viewer.setImageRows(newRows, columns: newColumns, rescale: true)
        }
    }

    // MARK: Releasing the series

    /// -finalizeSeriesViewing. The load is cancelled, the ROIs saved (a few
    /// images at a time when the viewer goes on with other slices,
    /// `viewerStays`) and announced as removed, and every movie frame's
    /// lists and volume released.
    func finalize(viewerStays: Bool) {
        let viewer = self.viewer
        cancel()

        if viewer.horos_resampleRatio != 1 {
            viewer.horos_resampleRatio = 1
        }

        let movieCount = Int(viewer.horos_maxMovieIndex)
        for movieIndex in 0..<max(movieCount, 0) {
            if let e = HorosObjCException.caught({ viewer.saveROI(movieIndex, later: viewerStays) }) {
                NSLog("***** saveROI exception : %@", e)
            }

            for case let rois as [Any] in viewer.horos_roiList(at: movieIndex) ?? [] {
                for case let roi as ROI in rois {
                    postViewerNotification(.OsirixRemoveROI, roi)
                }
            }
        }

        viewer.applyStatusValue()

        for movieIndex in 0..<max(movieCount, 0) {
            viewer.horos_setCopyRoiList(nil, at: movieIndex)
            viewer.horos_setRoiList(nil, at: movieIndex)
            viewer.horos_setPixList(nil, at: movieIndex)
            viewer.horos_setFileList(nil, at: movieIndex)

            viewer.horos_sendWillFreeVolumeDataNotification(forMovieIndex: movieIndex)
            viewer.horos_setVolumeData(nil, at: movieIndex)
        }

        viewer.horos_undoQueue?.removeAllObjects()
        viewer.horos_redoQueue?.removeAllObjects()
        viewer.clearVolumeLengthState()
        BrushReslice.forget(viewer)

        if viewer.horos_thickSlab != nil {
            viewer.horos_thickSlab = nil
        }
    }

    // MARK: Opening

    /// Stops the fit asked at opening: the operator acted on the images.
    func cancelOpeningScaleToFit() {
        viewer.horos_openingScaleToFitRequested = false
        viewer.imageViewsState.openingScaleToFit.cancelAll()
    }

    /// Asks the fit of the images to their content, a moment after they open,
    /// when the ScaleToFitOnOpen preference wants it.
    func requestOpeningScaleToFit() {
        let viewer = self.viewer
        cancelOpeningScaleToFit()
        if !preferences[ViewerPreferences.scaleToFitOnOpen] {
            return
        }
        viewer.horos_openingScaleToFitRequested = true
        // Open safely before the worker finishes the series envelope. Only this
        // pending request authorizes its later application, never a load callback.
        viewer.imageViewsState.openingScaleToFit.perform("finishOpeningScaleToFit", after: 0.1) { [weak viewer] in viewer?.finishOpeningScaleToFit() }
    }

    /// Fits each view to its series' content envelope once the series is
    /// loaded, or to its frame while it is still loading; waits while the
    /// windows are about to be tiled.
    func finishOpeningScaleToFit() {
        let viewer = self.viewer
        if !viewer.horos_openingScaleToFitRequested || viewer.horos_windowWillClose {
            return
        }
        if graph.processGraph.appController?.windowArranger.isTilingScheduled == true {
            // setImageRows and window tiling already have a deferred layout path.
            viewer.imageViewsState.openingScaleToFit.perform("finishOpeningScaleToFit", after: 0.1) { [weak viewer] in viewer?.finishOpeningScaleToFit() }
            return
        }
        if !preferences[ViewerPreferences.scaleToFitOnOpen] {
            cancelOpeningScaleToFit(); return
        }
        let pendingContent = viewer.horos_loadingThread != nil
        if !pendingContent { viewer.horos_openingScaleToFitRequested = false }
        viewer.window?.contentView?.layoutSubtreeIfNeeded()
        let wasUpdating = viewer.updateTilingViewsValue()
        viewer.setUpdateTilingViewsValue(true)
        // @try … @finally: the setting is restored, then the exception goes on.
        let e = HorosObjCException.caught {
            for case let view as DCMView in viewer.horos_seriesView?.imageViews() ?? [] {
                if (view.curDCM?.isLoaded() ?? false) && !NSIsEmptyRect(view.bounds) {
                    let envelope = pendingContent ? nil : viewer.horos_openingContentBoundsByPixels?[NSValue(nonretainedObject: view.dcmPixList)] as? NSValue
                    view.applyOpeningScale(toFit: envelope?.rectValue ?? NSRect.zero)
                }
            }
        }
        viewer.setUpdateTilingViewsValue(wasUpdating)
        if let e { e.raise() }
    }

    /// -showWindowTransition. The window takes the useful frame of the screen
    /// the MULTIPLESCREENS preference chooses, then the size WINDOWSIZEVIEWER
    /// gives it; the other viewers are told their default tool.
    func showWindowTransition() {
        let viewer = self.viewer
        let screens = NSScreen.screens
        let screen = screens.isEmpty ? nil : screens[SeriesLoadRules.openingScreen(multipleScreens: preferences[multipleScreens], screenCount: screens.count)]

        let screenRect = AppController.usefullRect(for: screen)

        viewer.window?.setFrame(screenRect, display: true)

        switch preferences[ViewerPreferences.viewerWindowSize] {
        case 0: viewer.setWindowFrame(screenRect, showWindow: false)
        case 1: viewer.horos_imageView?.resizeWindow(toScale: 1.0)
        case 2: viewer.horos_imageView?.resizeWindow(toScale: 1.5)
        case 3: viewer.horos_imageView?.resizeWindow(toScale: 2.0)
        default: break
        }

        if let other = graph.registry.displayedViewers.first(where: { $0 !== viewer }) {
            postViewerNotification(.OsirixDefaultToolModified, nil,
                     ["toolIndex": NSNumber(value: Int32(truncatingIfNeeded: other.imageView()?.currentTool.rawValue ?? 0))])
        }
    }

    /// -resampleDataIfNeeded:. A series of small images is resampled when it
    /// opens, as the ResampleData preferences ask, keeping its apparent size.
    func resampleIfNeeded() {
        autoreleasepool {
            guard preferences[resamplesSmallImages], let first = viewer.horos_pixList(at: 0)?.firstObject as? DCMPix else { return }
            guard let ratio = SeriesLoadRules.resampleRatio(width: Int32(truncatingIfNeeded: first.pwidth),
                                                            height: Int32(truncatingIfNeeded: first.pheight),
                                                            smallerOrEqual: Int32(truncatingIfNeeded: preferences[resamplingThreshold]),
                                                            destination: preferences[resamplingDestination]) else { return }
            let scale = viewer.horos_imageView?.scaleValue ?? 0
            if viewer.resampleData(withXFactor: ratio, yFactor: ratio, zFactor: 1.0) {
                viewer.horos_imageView?.scaleValue = scale * ratio
            }
        }
    }
}
