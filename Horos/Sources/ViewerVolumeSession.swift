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

/// NSAssert, which the Objective-C left enabled in every configuration: the
/// current NSAssertionHandler gets the failure, and by default raises
/// NSInternalInconsistencyException. The description has no format specifiers.
fileprivate func viewerVolumeAssertion(_ condition: Bool, _ description: String, in selector: Selector, object: AnyObject, line: Int = #line) {
    if condition { return }
    let handler = NSAssertionHandler.current
    let handleFailure = NSSelectorFromString("handleFailureInMethod:object:file:lineNumber:description:")
    typealias HandleFailure = @convention(c) (AnyObject, Selector, Selector, AnyObject, NSString, Int, NSString) -> Void
    let function = unsafeBitCast(handler.method(for: handleFailure), to: HandleFailure.self)
    function(handler, handleFailure, selector, object, "ViewerVolumeSession.swift", line, description as NSString)
}

/// The patient crosshair controller is main-actor isolated in Swift; the
/// Objective-C sent it -invalidateSession: from whatever thread closed the
/// session, without a check, and so does this.
fileprivate func viewerVolumeInvalidateCrosshair(_ session: VolumeSession) {
    let crosshair = (PatientCrosshairController.self as AnyObject).perform(NSSelectorFromString("shared"))!.takeUnretainedValue()
    _ = crosshair.perform(NSSelectorFromString("invalidateSession:"), with: session)
}

/// The per-viewer volume session holder, private to the former
/// ViewerVolumeSession.m. Public so that the executable keeps exporting the class.
@objc(HorosViewerVolumeContext)
public final class HorosViewerVolumeContext: NSObject {
    /// The viewer owns this context (an associated object) and outlives it; the
    /// Objective-C kept an unretained pointer. Weak, so a late notification
    /// finds nil instead of a released viewer.
    private weak var viewer: ViewerController?
    private let owner: String
    private var currentSession: VolumeSession?
    private var changing = false

    @objc(initWithViewer:)
    public init(viewer: ViewerController) {
        self.viewer = viewer
        self.owner = NSUUID().uuidString
        super.init()
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(close(_:)), name: .OsirixCloseViewer, object: viewer)
        nc.addObserver(self, selector: #selector(willChange(_:)), name: .OsirixViewerWillChange, object: viewer)
        nc.addObserver(self, selector: #selector(didChange(_:)), name: .OsirixViewerDidChange, object: viewer)
        nc.addObserver(self, selector: #selector(invalidate(_:)), name: .OsirixUpdateVolumeData, object: nil)
    }

    @objc(willChange:)
    public func willChange(_ notification: NSNotification?) {
        changing = true
        close(notification)
    }

    @objc(didChange:)
    public func didChange(_ notification: NSNotification?) { changing = false }

    @objc(close:)
    public func close(_ notification: NSNotification?) {
        if let session = currentSession {
            VolumeSessionRegistry.shared.close(session)
            viewerVolumeInvalidateCrosshair(session)
        }
        currentSession = nil
    }

    @objc(invalidate:)
    public func invalidate(_ notification: NSNotification?) {
        if !Thread.isMainThread {
            self.performSelector(onMainThread: #selector(invalidate(_:)), with: notification, waitUntilDone: false)
            return
        }
        if let session = currentSession, (notification?.object as AnyObject?) === (viewer?.pixList() as AnyObject?) {
            VolumeSessionRegistry.shared.invalidateVolume(session.identity)
            viewerVolumeInvalidateCrosshair(session)
        }
    }

    @objc(session)
    public func session() -> VolumeSession? {
        viewerVolumeAssertion(Thread.isMainThread, "Viewer volume access requires the main thread", in: #selector(session), object: self)
        if changing || (viewer?.windowWillClose() ?? false) { return nil }
        let image = viewer?.currentImage()
        var identity = VolumeIdentity(
            studyInstanceUID: image?.series?.study?.studyInstanceUID ?? "",
            // seriesInstanceUID is the catalog's grouping/sort key and can contain
            // a series-number prefix. The public identity uses DICOM (0020,000E).
            seriesInstanceUID: image?.series?.seriesDICOMUID ?? "",
            frameOfReferenceUID: viewer?.imageView()?.curDCM?.frameofReferenceUID ?? "",
            timeIndex: Int(viewer?.curMovieIndex() ?? 0), generation: 0)
        if identity == nil { close(nil); return nil }
        if let session = currentSession, session.isOpen, session.identity.refersToSameVolume(as: identity!) {
            if !session.isStale { return session }
            // Invalidation advances the identity and cancels old loads. Retire the
            // stale session so consumers can reopen, keeping that new generation.
            identity = session.identity
        }
        close(nil)
        currentSession = VolumeSessionRegistry.shared.open(identity: identity!, owner: owner)
        return currentSession
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        close(nil)
    }
}

/// The address of this variable is the associated-object key (the former static char).
fileprivate var horosViewerVolumeContextKey: UInt8 = 0

/// The ViewerController (HorosVolumeSession) category, in Swift since #722: the
/// selector and <Horos/ViewerVolumeSession.h> are those of the former category.
extension ViewerController {
    @objc(horosVolumeSession)
    public func horosVolumeSession() -> VolumeSession? {
        viewerVolumeAssertion(Thread.isMainThread, "Viewer volume access requires the main thread", in: #selector(horosVolumeSession), object: self)
        if self.windowWillClose() { return nil }
        var context = objc_getAssociatedObject(self, &horosViewerVolumeContextKey) as? HorosViewerVolumeContext
        if context == nil {
            context = HorosViewerVolumeContext(viewer: self)
            objc_setAssociatedObject(self, &horosViewerVolumeContextKey, context, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        return context!.session()
    }
}
