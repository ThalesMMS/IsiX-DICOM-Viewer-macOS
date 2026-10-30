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

// Notifications the viewer answers or posts for itself: another viewer
// closes (the fused one ends the fusion), the image view of this window
// changes (the tiling makes new views), and the volume data of a movie frame
// is freed or allocated (posted for plugins).

extension ViewerController {

    /// A viewer closes: the fused series, when it is the one, ends the
    /// fusion, and the main or key window's toolbar is refreshed.
    @objc(CloseViewerNotification:)
    func CloseViewerNotification(_ note: Notification!) {
        if (note?.object as AnyObject?) === horos_blending { // our blended serie is closing itself....
            activateBlending(nil)
        }

        if window?.isMainWindow ?? false || window?.isKeyWindow ?? false {
            refreshToolbar()
        }
    }

    /// The current image view changed (OsirixDCMUpdateCurrentImageNotification):
    /// the view of this window becomes the viewer's, and a tiled view updates
    /// its tiles.
    @objc(updateImageView:)
    func updateImageView(_ note: Notification!) {
        let view = note?.object as? DCMView
        guard let window, window.isEqual(view?.window) else { return }

        horos_imageView = view

        if (view?.columns ?? 0) != 1 || (view?.rows ?? 0) != 1 {
            view?.updateTilingViews()
        }
    }

    /// OsirixViewerControllerWillFreeVolumeDataNotification for the volume of
    /// `movieIndex`, when there is one.
    func horos_sendWillFreeVolumeDataNotification(forMovieIndex movieIndex: Int) {
        sendWillFreeVolumeDataNotification(withVolumeData: horos_volumeData(at: movieIndex), movieIndex: movieIndex)
    }

    /// OsirixViewerControllerDidAllocateVolumeDataNotification for the volume
    /// of `movieIndex`, when there is one.
    func horos_sendDidAllocateVolumeDataNotification(forMovieIndex movieIndex: Int) {
        sendDidAllocateVolumeDataNotification(withVolumeData: horos_volumeData(at: movieIndex), movieIndex: movieIndex)
    }

    /// OsirixViewerControllerWillFreeVolumeDataNotification with the volume
    /// ("volumeData") and the movie index ("movieIndex"), when there is a
    /// volume.
    @objc(sendWillFreeVolumeDataNotificationWithVolumeData:movieIndex:)
    func sendWillFreeVolumeDataNotification(withVolumeData volumeData: NSObject?, movieIndex: Int) {
        postVolumeDataNotification(.OsirixViewerControllerWillFreeVolumeData, volumeData: volumeData, movieIndex: movieIndex)
    }

    /// OsirixViewerControllerDidAllocateVolumeDataNotification with the volume
    /// ("volumeData") and the movie index ("movieIndex"), when there is a
    /// volume.
    @objc(sendDidAllocateVolumeDataNotificationWithVolumeData:movieIndex:)
    func sendDidAllocateVolumeDataNotification(withVolumeData volumeData: NSObject?, movieIndex: Int) {
        postVolumeDataNotification(.OsirixViewerControllerDidAllocateVolumeData, volumeData: volumeData, movieIndex: movieIndex)
    }

    /// The notification, in its own autorelease pool: the former code kept it
    /// against a crash in the run loop when the viewer was retained and
    /// autoreleased while it was freed.
    private func postVolumeDataNotification(_ name: Notification.Name, volumeData: NSObject?, movieIndex: Int) {
        guard let volumeData else { return }
        autoreleasepool {
            NotificationCenter.default.post(Notification(name: name, object: self,
                                                         userInfo: ["volumeData": volumeData, "movieIndex": NSNumber(value: movieIndex)]))
        }
    }
}
