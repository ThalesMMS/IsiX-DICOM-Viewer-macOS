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

/// The shared environment; `static OSIEnvironment *sharedEnvironment` of the
/// former OSIEnvironment.m.
// nonisolated(unsafe): +sharedEnvironment reads and writes it inside
// objc_sync_enter(OSIEnvironment.self); -init reads it either inside that call,
// while the environment is being made, or later, once it is set and no longer
// changes.
nonisolated(unsafe) private var sharedEnvironment: OSIEnvironment? = nil

/// The OSIEnvironment class is the main access point into the Horos Plugin SDK.
/// It provides access to the list of Viewer Windows that are currently open.
/// Whenever a Viewer Window is opened or closed a
/// `OSIEnvironmentOpenVolumeWindowsDidUpdateNotification` is posted.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/OSIEnvironment.h> are those of the former class, and
/// OSIEnvironment+Private.h still declares the application's methods, which the
/// extension below implements. The notification name and the singleton's
/// memory-management overrides stay in OSIEnvironment+CAPI.m.
@objc(OSIEnvironment)
public final class OSIEnvironment: NSObject {
    // Not optional, so that it has no initial value (an optional one would be nil): -init below initializes it,
    // and must be able to read it first.
    private var _volumeWindows: NSMutableDictionary

    public override class func automaticallyNotifiesObservers(forKey key: String) -> Bool {
        if key == "openVolumeWindows" {
            return false
        }

        return super.automaticallyNotifiesObservers(forKey: key)
    }

    /// Returns the shared `OSIEnvironment` instance.
    @objc(sharedEnvironment)
    public class func shared() -> OSIEnvironment! {
//    return nil; // because this is too slow on remote DBs, sorry... you're forcing us to load the complete series' DCMPix before showing the window :(

        objc_sync_enter(self)
        defer { objc_sync_exit(self) }
        if sharedEnvironment == nil {
            if UserDefaults.standard.bool(forKey: "OSIEnvironmentActivated") {
                sharedEnvironment = OSIEnvironmentCAPIAllocateSharedEnvironment()
            }
        }
        return sharedEnvironment
    }

    public override init() {
        // +allocWithZone: answers the shared environment, so [[OSIEnvironment alloc] init] runs this again on
        // it: it keeps the volume windows it has instead of starting an empty list. The environment is made
        // only by +sharedEnvironment, once, so the one found there is this one. The second initialization
        // does not release the value it replaces, here the same dictionary: one retain is left, on a list
        // the environment, never freed, holds for good.
        _volumeWindows = sharedEnvironment?._volumeWindows ?? NSMutableDictionary()
        super.init()
    }

    /// Returns the `OSIVolumeWindow` object that is paired with the given viewerController.
    @objc(volumeWindowForViewerController:)
    public func volumeWindow(for viewerController: ViewerController!) -> OSIVolumeWindow! {
        return _volumeWindows.object(forKey: key(viewerController)) as? OSIVolumeWindow
    }

    // I don't like the name because "open" can be taken to be meant as the verb not the adjective

    /// Returns an array of all the displayed Volume Windows. This property is
    /// observable using key-value observing.
    @objc(openVolumeWindows)
    public func openVolumeWindows() -> [Any]! {
        return _volumeWindows.allValues
    }

    /// Returns the frontmost Volume Window; not observable, nil if there is no
    /// reasonable frontmost controller.
    @objc(frontmostVolumeWindow)
    public func frontmostVolumeWindow() -> OSIVolumeWindow! {
        // Plugins ask from any thread; the window list is the main thread's.
        let viewerControllers = onMainActorSync { NSApp.orderedWindows.map { $0.windowController } }

        for windowController in viewerControllers {
            if let viewerController = windowController as? ViewerController {
                if let volumeWindow = self.volumeWindow(for: viewerController) {
                    return volumeWindow
                }
            }
        }

        return nil
    }

    /// `[NSValue valueWithPointer:viewerController]`, the key of the dictionary.
    fileprivate func key(_ viewerController: ViewerController?) -> NSValue {
        return NSValue(pointer: viewerController.map { UnsafeRawPointer(Unmanaged.passUnretained($0).toOpaque()) })
    }

    fileprivate var volumeWindows: NSMutableDictionary? { return _volumeWindows }
}

// OSIEnvironment (Private), declared in OSIEnvironment+Private.h.
extension OSIEnvironment {
    @objc(addViewerController:)
    func addViewerController(_ viewerController: ViewerController!) {
        assert(volumeWindows?.object(forKey: key(viewerController)) == nil) // already added this viewerController!

        let volumeWindow = OSIVolumeWindow(viewerController: viewerController)
        willChangeValue(forKey: "openVolumeWindows")
        volumeWindows?.setObject(volumeWindow as Any, forKey: key(viewerController))
        didChangeValue(forKey: "openVolumeWindows")
        NotificationCenter.default.post(name: NSNotification.Name.OSIEnvironmentOpenVolumeWindowsDidUpdate, object: nil)
    }

    @objc(removeViewerController:)
    func removeViewerController(_ viewerController: ViewerController!) {
        guard let object = volumeWindows?.object(forKey: key(viewerController)) else {
            // The environment exists only once OSIEnvironmentActivated is on, so a viewer opened before
            // that was never added. It closes with nothing to remove and nothing for observers to learn.
            return
        }
        assert(object is OSIVolumeWindow)
        let volumeWindow = object as! OSIVolumeWindow

        volumeWindow.viewerControllerDidClose()

        willChangeValue(forKey: "openVolumeWindows")
        volumeWindows?.removeObject(forKey: key(viewerController))
        didChangeValue(forKey: "openVolumeWindows")
        NotificationCenter.default.post(name: NSNotification.Name.OSIEnvironmentOpenVolumeWindowsDidUpdate, object: nil)
    }

    @objc(viewerControllerWillChangeData:)
    func viewerControllerWillChangeData(_ viewerController: ViewerController!) {
        // only do this if the volume window is already properly attached, this assumes that the first time the viewerController is initialized it will not have been added,
        // and therefore we will not send this notification for the original init
        if volumeWindows?.object(forKey: key(viewerController)) != nil {
            let object = volumeWindows?.object(forKey: key(viewerController))
            assert(object is OSIVolumeWindow)
            let volumeWindow = object as! OSIVolumeWindow

            volumeWindow.viewerControllerWillChangeData()
        }
    }

    @objc(viewerControllerDidChangeData:)
    func viewerControllerDidChangeData(_ viewerController: ViewerController!) {
        // only do this if the volume window is already properly attached, this assumes that the first time the viewerController is initialized it will not have been added,
        // and therefore we will not send this notification for the original init
        if volumeWindows?.object(forKey: key(viewerController)) != nil {
            let object = volumeWindows?.object(forKey: key(viewerController))
            assert(object is OSIVolumeWindow)
            let volumeWindow = object as! OSIVolumeWindow

            volumeWindow.viewerControllerDidChangeData()
        }
    }

    // Main actor: sent by -[DCMView drawRect:].
    @objc(drawDCMView:)
    @MainActor func drawDCMView(_ dcmView: DCMView!) {
        let viewerController = dcmView.windowController() as AnyObject?
        if let viewerController = viewerController as? ViewerController {
            let volumeWindow = self.volumeWindow(for: viewerController)
            volumeWindow?.draw(in: dcmView)
        }
    }
}
