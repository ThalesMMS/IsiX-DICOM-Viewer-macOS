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

/// -[ViewerController volumeData:], typed as NSData. The Swift import bridges
/// the result to Data, and it is this very object that the volume is built on
/// and whose address the viewer's notifications carry.
private func viewerVolumeData(_ viewerController: ViewerController?, _ index: Int) -> NSData? {
    guard let viewerController = viewerController else {
        return nil
    }
    typealias VolumeData = @convention(c) (AnyObject, Selector, Int) -> Unmanaged<NSData>?
    let selector = NSSelectorFromString("volumeData:")
    let implementation = unsafeBitCast(viewerController.method(for: selector), to: VolumeData.self)
    return implementation(viewerController, selector, index)?.takeUnretainedValue()
}

/// `[NSNumber numberWithInteger:(NSInteger)volumeData]`, the key of a volume's
/// data in _generatedFloatVolumeDataToInvalidate.
private func pointerKey(_ object: AnyObject) -> NSNumber {
    return NSNumber(value: Int(bitPattern: Unmanaged.passUnretained(object).toOpaque()))
}

// there is something fundamentally wrong with this. A lot of viewers display multiple images, and that MUST be handled correctly. This is particularly important for the plugin API
// because lots of plugins are used to perform specific tasks and that ofter requires windows with multiple view. It would be really nice if we could

/// Each instance of a OSIVolumeWindow is paired was an OsiriX `ViewerController`.
/// The goal of the Volume Window is to provide a simplified interface to common
/// tasks that are inherently difficult to do directly with a `ViewerController`.
///
/// Implemented in Swift since #828: the Objective-C name, the selectors and
/// <Horos/OSIVolumeWindow.h> are those of the former class, and
/// OSIVolumeWindow+Private.h still declares the application's methods, which
/// the extension below implements. The notification names, the variadic
/// -floatVolumeDataForDimensionsAndIndexes: and -init stay in
/// OSIVolumeWindow+CAPI.m.
@objc(OSIVolumeWindow)
public final class OSIVolumeWindow: NSObject, OSIROIManagerDelegate, OSIVolumeWindowVariadic {
    fileprivate var _viewerController: ViewerController? = nil // this is retained
    fileprivate var _ROIManager: OSIROIManager? = nil // should this really be an ROI manager? or is that another beast altogether?

    // we want to keep track of OSIFloatVolumeData objects that have been generated so that we can invalidate them. The key is the pointer to the NSData in the ViewerController
    private var _generatedFloatVolumeDataToInvalidate: NSMutableDictionary? = nil
    private var _generatedFloatVolumeDatas: NSMutableDictionary? = nil // The lazily created VolumeDatas
    private var _OSIROIs: NSMutableArray? = nil // additional ROIs that have been added to the VolumeWindow

    private var _dataLoaded = false

    public override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        if key == "dataLoaded" {
            return false
        }

        return super.automaticallyNotifiesObservers(forKey: key)
    }

    // OSIVolumeWindow (Private), declared in OSIVolumeWindow+Private.h. The
    // -init that refuses is in OSIVolumeWindow+CAPI.m.
    @objc(initWithViewerController:)
    init(viewerController: ViewerController!) {
        _viewerController = viewerController
        _OSIROIs = NSMutableArray()
        _generatedFloatVolumeDatas = NSMutableDictionary()
        _generatedFloatVolumeDataToInvalidate = NSMutableDictionary()

        _dataLoaded = viewerController?.isEverythingLoaded() ?? false
        super.init()
        if _dataLoaded == false {
            NotificationCenter.default.addObserver(self, selector: #selector(_viewerControllerDidLoadImagesNotification(_:)), name: NSNotification.Name.OsirixViewerControllerDidLoadImages, object: _viewerController)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(_viewerControllerWillFreeVolumeDataNotification(_:)), name: NSNotification.Name.OsirixViewerControllerWillFreeVolumeData, object: _viewerController)
        NotificationCenter.default.addObserver(self, selector: #selector(_viewerControllerDidAllocateVolumeDataNotification(_:)), name: NSNotification.Name.OsirixViewerControllerDidAllocateVolumeData, object: _viewerController)

        _ROIManager = OSIROIManager(volumeWindow: self)
        _ROIManager?.delegate = self
    }

    deinit {
        NotificationCenter.default.removeObserver(self)

        _viewerController = nil
        _ROIManager?.delegate = nil
        _ROIManager = nil
        _OSIROIs = nil
        _generatedFloatVolumeDatas = nil
        _generatedFloatVolumeDataToInvalidate = nil
    }

    /// The ViewerController this Volume Window is paired with, nil once it closed.
    /// If you really want to go into the depths of OsiriX, use at your own peril!
    @objc(viewerController)
    public func viewerController() -> ViewerController! {
        return _viewerController
    }

    /// Observable. Is this VolumeWindow actually connected to a ViewerController.
    /// If the ViewerController is closed, the connection will be lost but if the
    /// plugin is lazy and doesn't close things properly, at least the
    /// ViewerController will be released, the memory will be released, and the
    /// plugin will just be holding on to a super lightweight object
    @objc(isOpen)
    public func isOpen() -> Bool {
        return (_viewerController != nil ? true : false)
    }

    /// Observable.
    @objc(isDataLoaded)
    public func isDataLoaded() -> Bool {
        return _dataLoaded
    }

    /// Do not mess with the delegate of this ROI manager, but feel free to ask
    /// it for its list of ROIs.
    @objc(ROIManager)
    public func roiManager() -> OSIROIManager! {
        return _ROIManager
    }

    /// The title of the window represented by this Volume Window.
    @objc(title)
    public func title() -> String! {
        return _viewerController?.window?.title
    }

    /// Dimensions other than the 3 natural dimensions, time for example.
    @objc(dimensions)
    public func dimensions() -> [Any]! {
        if (_viewerController?.maxMovieIndex() ?? 0) > 1 {
            return ["movieIndex"]
        } else {
            return []
        }
    }

    /// The number of frames available in the given dimension.
    @objc(depthOfDimension:)
    public func depth(ofDimension dimension: String!) -> UInt {
        if let dimension = dimension, (dimension as NSString).isEqual(to: "movieIndex") {
            return UInt(bitPattern: Int(_viewerController?.maxMovieIndex() ?? 0))
        } else {
            return 0
        }
    }

    /// The Volume Data for the dimension coordinates.
    @objc(floatVolumeDataForDimensions:indexes:)
    public func floatVolumeData(forDimensions dimensions: [Any]!, indexes: [Any]!) -> OSIFloatVolumeData! {
        assert(dimensions.count == 1)
        assert(indexes.count == 1)

        assert((dimensions[0] as AnyObject).isEqual(to: "movieIndex"))
        assert(indexes[0] is NSNumber)

        let dimensionAndIndexKey = String(format: "movieIndex_%@", indexes[0] as! CVarArg) // THIS is totally bogus once we handle more than one dimension

        var floatVolumeData = _generatedFloatVolumeDatas?.object(forKey: dimensionAndIndexKey) as? OSIFloatVolumeData
        if let existing = floatVolumeData {
            if existing.isDataValid() {
                return existing
            } else {
                _generatedFloatVolumeDatas?.removeObject(forKey: dimensionAndIndexKey)
            }
        }

        let index = (indexes[0] as AnyObject).integerValue ?? 0
        let pixList = _viewerController?.pixList(index)
        let volumeData = viewerVolumeData(_viewerController, index)

        assert(pixList != nil)
        assert(volumeData != nil)

        _ = _viewerController?.computeInterval()
        floatVolumeData = OSIFloatVolumeData(withPixList: pixList, volume: volumeData)

        _generatedFloatVolumeDatas?.setObject(floatVolumeData as Any, forKey: dimensionAndIndexKey as NSString)
        _generatedFloatVolumeDataToInvalidate?.setObject(floatVolumeData as Any, forKey: pointerKey(volumeData as AnyObject))

        return floatVolumeData
    }

    @objc(addOSIROI:)
    public func addOSIROI(_ roi: OSIROI!) {
        let rois = mutableArrayValue(forKey: "OSIROIs")
        rois.add(roi as Any)
    }

    @objc(removeOSIROI:)
    public func removeOSIROI(_ roi: OSIROI!) {
        let rois = mutableArrayValue(forKey: "OSIROIs")
        rois.remove(roi as Any)
    }

    /// Observable.
    @objc(OSIROIs)
    public func OSIROIs() -> NSArray! {
        return _OSIROIs
    }

    // What -mutableArrayValueForKey:@"OSIROIs" mutates. The former class had no
    // accessors, and KVC reached its _OSIROIs ivar directly; Swift has no
    // instance variable KVC can reach, so these two do what the proxy did.
    @objc(insertObject:inOSIROIsAtIndex:)
    private func insertObject(_ roi: AnyObject, inOSIROIsAt index: Int) {
        _OSIROIs?.insert(roi, at: index)
    }

    @objc(removeObjectFromOSIROIsAtIndex:)
    private func removeObjectFromOSIROIs(at index: Int) {
        _OSIROIs?.removeObject(at: index)
    }

    @objc(_viewerControllerDidLoadImagesNotification:)
    private func _viewerControllerDidLoadImagesNotification(_ notification: Notification) {
        let viewerController = notification.object as AnyObject?

        assert(viewerController is ViewerController)
        if (viewerController is ViewerController) == false {
            NSLog("_viewerControllerDidLoadImagesNotification: recieved an object that is not ViewerController")
            return
        }

        assert(viewerController === _viewerController)
        if viewerController !== _viewerController {
            NSLog("_viewerControllerDidLoadImagesNotification: recieved the wrong viewerController")
            return
        }

        willChangeValue(forKey: "dataLoaded")
        _dataLoaded = true
        didChangeValue(forKey: "dataLoaded")

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.OsirixViewerControllerDidLoadImages, object: _viewerController)
    }

    @objc(_viewerControllerWillFreeVolumeDataNotification:)
    private func _viewerControllerWillFreeVolumeDataNotification(_ notification: Notification) {
        assert(Thread.isMainThread)

        let volumeData = notification.userInfo?["volumeData"] as AnyObject?
        assert(volumeData != nil)

        let key = pointerKey(volumeData as AnyObject)
        let floatVolumeData = _generatedFloatVolumeDataToInvalidate?.object(forKey: key) as? OSIFloatVolumeData
        if let floatVolumeData = floatVolumeData {
            floatVolumeData.invalidateData()
            _generatedFloatVolumeDataToInvalidate?.removeObject(forKey: key)
        }
    }

    @objc(_viewerControllerDidAllocateVolumeDataNotification:)
    private func _viewerControllerDidAllocateVolumeDataNotification(_ notification: Notification) {
        // Do something here
    }
}

// OSIVolumeWindow (Private), declared in OSIVolumeWindow+Private.h.
extension OSIVolumeWindow {
    @objc(viewerControllerDidClose)
    func viewerControllerDidClose() {
        willChangeValue(forKey: "open")
        _viewerController = nil
        didChangeValue(forKey: "open")
        NotificationCenter.default.post(name: NSNotification.Name.OSIVolumeWindowDidClose, object: self)
    }

    @objc(viewerControllerWillChangeData)
    func viewerControllerWillChangeData() {
        NotificationCenter.default.post(name: NSNotification.Name.OSIVolumeWindowWillChangeData, object: self)
    }

    @objc(viewerControllerDidChangeData)
    func viewerControllerDidChangeData() {
        NotificationCenter.default.post(name: NSNotification.Name.OSIVolumeWindowDidChangeData, object: self)
    }

    @objc(drawInDCMView:)
    func draw(in dcmView: DCMView!) {
        _ROIManager?.draw(in: dcmView)
    }

    @objc(setNeedsDisplay)
    func setNeedsDisplay() {
        _viewerController?.imageView()?.needsDisplay = true
        for dcmView in _viewerController?.imageViews() ?? [] {
            (dcmView as? DCMView)?.needsDisplay = true
        }
    }
}
