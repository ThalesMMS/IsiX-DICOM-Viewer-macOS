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

// The life of the viewer as an object: what its initializer does once the
// window controller exists, the set-up of the window and its observers, the
// nib's awakening and what the viewer gives back before it goes (deinit).
// The viewer's graph runs them (ViewerSessionGraph+ViewerLife.swift); these
// are the selectors of the former Objective-C class.

extension ViewerController {

    /// The former -initWithPix:withFiles:withVolume: after
    /// [super initWithWindowNibName:@"Viewer"]: the toolbar items and undo
    /// queues, what the graph prepares, the set-up of the window, the data
    /// (the files as given, nil when there are none), then the rest.
    @objc(horosFinishInitializationWithPix:files:volume:)
    func horosFinishInitialization(pix f: NSMutableArray!, files d: NSMutableArray!, volume v: NSData!) {
        horos_retainedToolbarItems = NSMutableArray(capacity: 0)
        horos_undoQueue = NSMutableArray(capacity: 0)
        horos_redoQueue = NSMutableArray(capacity: 0)
        sessionGraph.prepareViewer(showing: d?.object(at: 0) as? DicomImage)
        viewerControllerInit()
        changeImageData(f, (d?.count ?? 0) == 0 ? nil : d, v, true)
        sessionGraph.completeViewerInitialization()
    }

    @objc(viewerControllerInit)
    func viewerControllerInit() {
        sessionGraph.setUpViewer()
    }

    @objc(awakeFromNib)
    public override func awakeFromNib() {
        // A nib wakes its owner on the main thread.
        MainActor.assumeIsolated {
            sessionGraph?.awakeFromViewerNib()
        }
    }

    @objc(horosTearDown)
    func horosTearDown() {
        sessionGraph?.tearDown(self)
    }
}
