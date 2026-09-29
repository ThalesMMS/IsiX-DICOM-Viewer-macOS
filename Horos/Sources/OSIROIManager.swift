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

import Cocoa

/// -[NSString isEqualToString:]: literal comparison, and NO for nil.
private func isEqualToString(_ string: String?, _ other: String?) -> Bool {
    guard let string = string, let other = other else {
        return false
    }
    return (string as NSString).isEqual(to: other)
}

/// -addObject: of NSMutableArray or NSMutableSet, which raises for nil as the
/// former code did.
private func addObject(_ collection: NSObject?, _ object: Any?) {
    _ = collection?.perform(NSSelectorFromString("addObject:"), with: object)
}

/// -[NSMutableDictionary setObject:forKey:], which raises for a nil key as the
/// former code did.
private func setObject(_ dictionary: NSMutableDictionary, _ object: Any?, _ key: Any?) {
    _ = dictionary.perform(NSSelectorFromString("setObject:forKey:"), with: object, with: key)
}

// anyone who is interested in dealing with ROIs can create one of these and learn about what is going on with ROIs
// and OSIROIManager is meant to act as a filter, it will return ROIs
// what I want is an object that will give me a list of volume ROIs

/// The `OSIROIManager` class defines the interface to discover ROIs and filter
/// for the ROIs of interest. After creating an instance of `OSIROIManager` a
/// client can use it to get an array of ROIs and can register itself as a
/// delegate to recieve updates about the ROIs in the given `OSIVolumeWindow`.
/// It sends a `OSIROIManagerROIsDidUpdateNotification` whenever there is any
/// change in the managed ROIs.
///
/// Implemented in Swift since #828: the Objective-C name, the selectors and
/// <Horos/OSIROIManager.h> are those of the former class, and
/// OSIROIManager+Private.h still declares -drawInDCMView:, which the extension
/// below implements. The notification names stay in OSIROIManager+CAPI.m.
@objc(OSIROIManager)
public final class OSIROIManager: NSObject {

    private var _volumeWindow: OSIVolumeWindow? = nil
    private var _coalesceROIs = false

    private var _allROIsLoaded = false

    private var _rebuildingROIs = false

    private var _addedOSIROIs: NSMutableArray? = nil
    private var _OSIROIs: NSMutableArray? = nil
    private var _watchedROIs: NSMutableSet? = nil // the osirix ROIs that are backing the OSIROIs that are being managed. These are the ROIs that need to be watched, and the OSIROIs need to be updated when these change

    /// The receiver’s delegate or nil if it doesn’t have a delegate; assigned,
    /// not retained.
    @objc public unowned(unsafe) var delegate: OSIROIManagerDelegate? = nil

    /// The OSIVolumeWindow to which this ROIManager is attached.
    @objc public var volumeWindow: OSIVolumeWindow! {
        return _volumeWindow
    }

    public override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        if key == "allROIsLoaded" {
            return false
        }

        return super.automaticallyNotifiesObservers(forKey: key)
    }

    /// Initializes and returns a newly created ROI Manager, not coalescing ROIs
    /// with the same name.
    @objc(initWithVolumeWindow:)
    public convenience init(volumeWindow: OSIVolumeWindow!) {
        self.init(volumeWindow: volumeWindow, coalesceROIs: false)
    }

    /// Initializes the newly created ROI Manager to look in volumeWindow for
    /// ROIs, and optionally coalesces ROI with the same name into a single
    /// volumetric ROI.
    @objc(initWithVolumeWindow:coalesceROIs:)
    public init(volumeWindow: OSIVolumeWindow!, coalesceROIs: Bool) { // if coalesceROIs is YES, ROIs with the same name will
        _volumeWindow = volumeWindow // it is ok to retain the volumeWindow even if this is the ROIManager that is owned by an OSIVolumeWindow because it will be released when the window closes
        _OSIROIs = NSMutableArray()
        _addedOSIROIs = NSMutableArray()
        _watchedROIs = NSMutableSet()
        _coalesceROIs = coalesceROIs
        _allROIsLoaded = volumeWindow?.isDataLoaded() ?? false
        super.init()
        _rebuildOSIROIs()
        NotificationCenter.default.addObserver(self, selector: #selector(_volumeWindowDidCloseNotification(_:)), name: NSNotification.Name.OSIVolumeWindowDidClose, object: _volumeWindow)
        NotificationCenter.default.addObserver(self, selector: #selector(_ROIChangeNotification(_:)), name: NSNotification.Name.OsirixROIChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_removeROINotification(_:)), name: NSNotification.Name.OsirixRemoveROI, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_addROINotification(_:)), name: NSNotification.Name.OsirixAddROI, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(_volumeWindowDidChangeDataNotification(_:)), name: NSNotification.Name.OSIVolumeWindowDidChangeData, object: nil)

        _volumeWindow?.addObserver(self, forKeyPath: "OSIROIs", options: .initial, context: Unmanaged.passUnretained(self).toOpaque())
        _volumeWindow?.addObserver(self, forKeyPath: "dataLoaded", options: .initial, context: Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        NSObject.cancelPreviousPerformRequests(withTarget: self)

        NotificationCenter.default.removeObserver(self)
        _volumeWindow?.removeObserver(self, forKeyPath: "OSIROIs")
        _volumeWindow?.removeObserver(self, forKeyPath: "dataLoaded")

        delegate = nil

        _volumeWindow = nil
        _OSIROIs = nil
        _addedOSIROIs = nil
        _watchedROIs = nil
    }

    /// Returns the array OSIROI objects the reciever is managing. Observable.
    @objc(ROIs)
    public func rois() -> [Any]! {
        let rois = NSMutableArray(array: _addedOSIROIs as? [Any] ?? [])
        rois.addObjects(from: _OSIROIs as? [Any] ?? [])
        return rois as? [Any]
    }

    /// Returns the first ROI with a given name that would be in the ROI array.
    @objc(firstROIWithName:)
    public func firstROI(withName name: String!) -> OSIROI! { // convenience method to get the first ROI with
        let rois = self.rois(withName: name) ?? []

        if rois.count > 0 {
            return rois[0] as? OSIROI
        } else {
            return nil
        }
    }

    /// Returns all the ROIs managed by the receiver that have the given name.
    @objc(ROIsWithName:)
    public func rois(withName name: String!) -> [Any]! {
        let rois = NSMutableArray()
        for roi in _addedOSIROIs ?? [] {
            if isEqualToString((roi as! OSIROI).name(), name) {
                rois.add(roi)
            }
        }
        for roi in _OSIROIs ?? [] {
            if isEqualToString((roi as! OSIROI).name(), name) {
                rois.add(roi)
            }
        }
        return rois as? [Any]
    }

    /// Returns the first ROI with a given name that would be in the ROI array
    /// and is currently visible to the user.
    @objc(firstVisibleROIWithName:)
    public func firstVisibleROI(withName name: String!) -> OSIROI! {
        let volumeWindow = self._volumeWindow
        let viewerController = volumeWindow?.viewerController()
        let dcmView = viewerController?.imageView()
        let dcmROIs = NSSet(array: dcmView?.curRoiList as? [Any] ?? [])

        for roi in self.rois(withName: name) ?? [] {
            let roi = roi as! OSIROI
            let osirixROIs = roi.osiriXROIs() as NSSet?
            if (osirixROIs?.count ?? 0) == 0 {
                return roi
            }
            if osirixROIs!.intersects(dcmROIs as! Set<AnyHashable>) {
                return roi
            }
        }
        return nil
    }

    /// Returns the first ROI with a whose name starts wth `prefix` that would
    /// be in the ROI array and is currently visible to the user.
    @objc(firstVisibleROIWithNamePrefix:)
    public func firstVisibleROI(withNamePrefix prefix: String!) -> OSIROI! {
        var roi: OSIROI? = nil

        for roiName in self.roiNames() ?? [] {
            if (roiName as! NSString).hasPrefix(prefix) {
                roi = self.firstVisibleROI(withName: roiName as? String)
                if roi != nil {
                    return roi
                }
            }
        }
        return nil
    }

    /// Returns `NSString` objects representing the names of all the ROIs
    /// managed by the receiver; all the unique ROI names.
    @objc(ROINames)
    public func roiNames() -> [Any]! {
        let roiNames = NSMutableSet()

        for roi in _addedOSIROIs ?? [] {
            let name = (roi as! OSIROI).name()
            if name.map({ roiNames.contains($0) }) != true {
                addObject(roiNames, name)
            }
        }
        for roi in _OSIROIs ?? [] {
            let name = (roi as! OSIROI).name()
            if name.map({ roiNames.contains($0) }) != true {
                addObject(roiNames, name)
            }
        }

        return roiNames.allObjects
    }

    /// Returns YES if all the ROIs in the volume have been loaded. Observable.
    @objc(allROIsLoaded)
    public func allROIsLoaded() -> Bool {
        return _allROIsLoaded
    }

    public override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "OSIROIs" && (object as AnyObject?) === _volumeWindow {
            _rebuildOSIROIs()
        } else if keyPath == "dataLoaded" && (object as AnyObject?) === _volumeWindow {
            willChangeValue(forKey: "allROIsLoaded")
            _allROIsLoaded = _volumeWindow?.isDataLoaded() ?? false
            didChangeValue(forKey: "allROIsLoaded")
            _rebuildOSIROIs()
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }

    @objc(_volumeWindowDidCloseNotification:)
    private func _volumeWindowDidCloseNotification(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.OSIVolumeWindowDidClose, object: _volumeWindow)
        _volumeWindow?.removeObserver(self, forKeyPath: "OSIROIs")
        _volumeWindow?.removeObserver(self, forKeyPath: "dataLoaded")
        _volumeWindow = nil
        _rebuildOSIROIs()
    }

    @objc(_ROIChangeNotification:)
    private func _ROIChangeNotification(_ notification: Notification) {
        if _isROIManaged(notification.object as? ROI) {
            _rebuildOSIROIs()
        }
    }

    @objc(_removeROINotification:)
    private func _removeROINotification(_ notification: Notification) {
        if _isROIManaged(notification.object as? ROI) {
            assert(Thread.isMainThread)
            perform(#selector(_removeROICallbackHack(_:)), with: notification.object, afterDelay: 0) // OsiriX manages to send this notification before the ROI is
            // actually removed. This super ultra sketchy bit of code copies the stratagy used by ROIManagerController
        }
    }

    @objc(_removeROICallbackHack:)
    private func _removeROICallbackHack(_ roi: ROI?) {
        _rebuildOSIROIs()
        if let volumeWindow = delegate as? OSIVolumeWindow { // This is the a OSIROIManager owned by a volume window
            volumeWindow.viewerController()?.window?.viewsNeedDisplay = true
        }
    }

    @objc(_addROINotification:)
    private func _addROINotification(_ notification: Notification) {
        _rebuildOSIROIs()
    }

    @objc(_volumeWindowDidChangeDataNotification:)
    private func _volumeWindowDidChangeDataNotification(_ notification: Notification) {
        _rebuildOSIROIs()
    }

    @objc(_isROIManaged:)
    private func _isROIManaged(_ roi: ROI?) -> Bool {
        return _watchedROIs?.contains(roi as Any) ?? false
    }

    @objc(_rebuildOSIROIs)
    private func _rebuildOSIROIs() {
        var watchedROIs: NSArray? = nil

        // because the OsiriX ROI posts notifications at super weird times (like within dealloc!?!?!)
        // we need to make sure we don't renter our ROI rebuilding call while rebuilding the ROIs;

        if _rebuildingROIs {
            return
        }

        if _volumeWindow != nil && _allROIsLoaded == false { // don't do jack until everything is loaded
            return
        }

        autoreleasepool {
            _rebuildingROIs = true

            let oldOSIROIs = NSArray(array: _OSIROIs as? [Any] ?? [])

            willChangeValue(forKey: "ROIs")
            _OSIROIs?.removeAllObjects()
            _watchedROIs?.removeAllObjects()
            if _coalesceROIs {
                _OSIROIs?.addObjects(from: _coalescedROIList(forWatchedOsiriXROIs: &watchedROIs) as? [Any] ?? [])
            } else {
                _OSIROIs?.addObjects(from: _ROIList(forWatchedOsiriXROIs: &watchedROIs) as? [Any] ?? [])
            }
            didChangeValue(forKey: "ROIs")

            _watchedROIs?.addObjects(from: watchedROIs as? [Any] ?? [])

            let userInfoDict: [AnyHashable: Any] = [OSIROIRemovedROIKey: oldOSIROIs,
                                                    OSIROIAddedROIKey: _OSIROIs as Any, OSIROIUpdatedROIKey: NSArray()]

            NotificationCenter.default.post(name: NSNotification.Name.OSIROIManagerROIsDidUpdate, object: self, userInfo: userInfoDict)

            _rebuildingROIs = false
        }
    }

    // returned watchedROI is the OsiriX rois the returned OSIROIs are based on
    @objc(_ROIListForWatchedOsiriXROIs:)
    private func _ROIList(forWatchedOsiriXROIs watchedROIs: AutoreleasingUnsafeMutablePointer<NSArray?>?) -> NSArray {
        let newROIs = NSMutableArray()
        var mutableWatchedROIs: NSMutableArray? = nil
        if watchedROIs != nil {
            mutableWatchedROIs = NSMutableArray()
        }

        let viewController = _volumeWindow?.viewerController()
        if let viewController = viewController {
            let maxMovieIndex = Int(viewController.maxMovieIndex())

            var i = 0
            while i < maxMovieIndex {
                let movieFrameROIList = viewController.roiList(i)
                let movieFramePixList = viewController.pixList(i)

                var j = 0
                while j < (movieFramePixList?.count ?? 0) {
                    let pix = movieFramePixList!.object(at: j) as! DCMPix
                    let pixROIList = movieFrameROIList?.object(at: j) as? NSArray

                    var pixToDicomTransform = pix.pixToDicomTransform()
                    if N3AffineTransformDeterminant(pixToDicomTransform) == 0.0 {
                        pixToDicomTransform = N3AffineTransformIdentity
                    }

                    for osirixROI in pixROIList ?? [] {
                        // -floatVolumeDataForDimensionsAndIndexes:@"movieIndex", i, nil, which Swift cannot call, builds these two arrays
                        let roi = OSIROI.roi(withOsiriXROI: osirixROI as? ROI, pixToDICOMTransfrom: pixToDicomTransform, homeFloatVolumeData: _volumeWindow?.floatVolumeData(forDimensions: ["movieIndex"], indexes: [NSNumber(value: i)])) as AnyObject?
                        if let roi = roi {
                            newROIs.add(roi)
                            mutableWatchedROIs?.add(osirixROI)
                        }
                    }
                    j += 1
                }
                i += 1
            }

            for roi in _volumeWindow?.OSIROIs() ?? [] {
                newROIs.add(roi)
            }
        }

        if let watchedROIs = watchedROIs {
            watchedROIs.pointee = mutableWatchedROIs
        }

        return newROIs
    }

    @objc(_coalescedROIListForWatchedOsiriXROIs:)
    private func _coalescedROIList(forWatchedOsiriXROIs watchedROIs: AutoreleasingUnsafeMutablePointer<NSArray?>?) -> NSArray {
        let roiList = _ROIList(forWatchedOsiriXROIs: watchedROIs)
        let roiNames = NSMutableSet()
        let coalescedROIs = NSMutableArray()
        let groupedNamesDict = NSMutableDictionary()

        for roi in roiList {
            let name = (roi as! OSIROI).name()
            if name.map({ roiNames.contains($0) }) != true {
                addObject(roiNames, name)
            }
        }

        for name in roiNames {
            setObject(groupedNamesDict, NSMutableArray(), name)
        }

        for roi in roiList {
            let group = (roi as! OSIROI).name().flatMap { groupedNamesDict.object(forKey: $0) } as? NSMutableArray
            addObject(group, roi)
        }

        for roisToCoalesce in groupedNamesDict.allValues {
            let roisToCoalesce = roisToCoalesce as! NSArray
            let homeVolumeData = (roisToCoalesce.object(at: 0) as! OSIROI).homeFloatVolumeData()
            let roi = OSIROI.roiCoalesced(withSourceROIs: roisToCoalesce as? [Any], homeFloatVolumeData: homeVolumeData) as AnyObject?
            if let roi = roi {
                coalescedROIs.add(roi)
            }
        }

        return coalescedROIs
    }

    /// Add an OSIROI to the manager. This is useful to have the ROIManager
    /// handle drawing of the ROI.
    @objc(addROI:)
    public func addROI(_ roi: OSIROI!) {
        willChangeValue(forKey: "ROIs")
        _addedOSIROIs?.add(roi as Any)
        didChangeValue(forKey: "ROIs")

        let userInfoDict: [AnyHashable: Any] = [OSIROIRemovedROIKey: NSArray(),
                                                OSIROIAddedROIKey: NSArray(object: roi as Any), OSIROIUpdatedROIKey: NSArray()]

        NotificationCenter.default.post(name: NSNotification.Name.OSIROIManagerROIsDidUpdate, object: self, userInfo: userInfoDict)
        _volumeWindow?.setNeedsDisplay()
    }

    /// Remove an OSIROI that was added. This is useful to have the ROIManager
    /// handle drawing of the ROI.
    @objc(removeROI:)
    public func removeROI(_ roi: OSIROI!) {
        willChangeValue(forKey: "ROIs")
        _addedOSIROIs?.remove(roi as Any)
        didChangeValue(forKey: "ROIs")

        let userInfoDict: [AnyHashable: Any] = [OSIROIRemovedROIKey: NSArray(object: roi as Any),
                                                OSIROIAddedROIKey: NSArray(), OSIROIUpdatedROIKey: NSArray()]

        NotificationCenter.default.post(name: NSNotification.Name.OSIROIManagerROIsDidUpdate, object: self, userInfo: userInfoDict)

        NotificationCenter.default.post(name: NSNotification.Name.OSIROIManagerROIsDidUpdate, object: self)
        _volumeWindow?.setNeedsDisplay()
    }
}

// OSIROIManager (Private), declared in OSIROIManager+Private.h.
extension OSIROIManager {
    @objc(drawInDCMView:)
    func draw(in dcmView: DCMView!) {
        var pixToDicomTransform: N3AffineTransform
        var dicomToPixTransform: N3AffineTransform
        var pixToSubdrawRectTransform = [Double](repeating: 0, count: 16)
        var plane: N3Plane
        var slab = OSISlab()

        if (self.delegate is OSIVolumeWindow) == false { // only draw ROIs for the ROIs in an ROI manager that is owned by the VolumeWindow
            return
        }

        N3AffineTransformGetOpenGLMatrixd(dcmView.pixToSubDrawRectTransform(), &pixToSubdrawRectTransform)
        pixToDicomTransform = dcmView.curDCM.pixToDicomTransform()
        if N3AffineTransformDeterminant(pixToDicomTransform) != 0.0 {
            dicomToPixTransform = N3AffineTransformInvert(pixToDicomTransform)
            plane = N3PlaneApplyTransform(N3PlaneZZero, pixToDicomTransform)
        } else {
            dicomToPixTransform = N3AffineTransformIdentity
            plane = N3PlaneZZero
        }
        slab.thickness = CGFloat(dcmView.curDCM.sliceThickness)
        slab.plane = plane

        // The ROIs draw on the view's canvas (#727). This returned early without an
        // OpenGL context, which there has not been since #728, so nothing drew (#735).
        let former = NSSelectorFromString("drawSlab:inCGLContext:pixelFormat:dicomToPixTransform:")
        for roi in self.rois() ?? [] {
            let roi = roi as! OSIROI
            if (roi.osiriXROIs()?.count ?? 0) != 0 { continue } // backed by an old-style ROI, which draws itself
            ROICanvas.current?.pushMatrix()
            ROICanvas.current?.mult(pixToSubdrawRectTransform)
            if roi.responds(to: former) {
                // A plugin's subclass written for the former selector: its OpenGL
                // arguments were unused since #727, and are NULL.
                typealias FormerDrawSlab = @convention(c) (AnyObject, Selector, OSISlab, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, N3AffineTransform) -> Void
                let formerDrawSlab = unsafeBitCast(roi.method(for: former), to: FormerDrawSlab.self)
                formerDrawSlab(roi, former, slab, nil, nil, dicomToPixTransform)
            } else {
                roi.draw(slab, dicomToPixTransform: dicomToPixTransform)
            }
            ROICanvas.current?.popMatrix()
        }
    }
}
