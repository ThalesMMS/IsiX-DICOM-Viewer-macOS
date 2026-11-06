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

// The saved layout of the 2D viewers ("windows state"): the menu items and
// the naming sheet of a viewer, and the class methods the application and
// plugins call. They are the selectors of the former Objective-C methods, a
// façade over ViewerWorkspaceArchiver.

public extension ViewerController {

    /// Forgets the saved layout of the studies on screen.
    @objc(resetWindowsState:)
    func resetWindowsState(_ sender: Any!) {
        ViewerWorkspaceArchiver(processGraph: sessionGraph.processGraph).reset()
    }

    /// Opens this viewer's study again with its saved layout.
    @objc(loadWindowsState:)
    func loadWindowsState(_ sender: Any!) {
        ViewerWorkspaceArchiver(processGraph: sessionGraph.processGraph).reopenStudy(of: self)
    }

    @objc(saveWindowsState:)
    func saveWindowsState(_ sender: Any!) {
        ViewerController.saveWindowsState()
    }

    /// Asks for the name of the layout, then archives it as a DICOM SR.
    @objc(saveWindowsStateAsDICOMSR:)
    func saveWindowsStateAsDICOMSR(_ sender: Any!) {
        ViewerWorkspaceArchiver(processGraph: sessionGraph.processGraph).askNameForDICOMSR(in: self)
    }

    @objc(endSaveWindowsStateAsDICOMSR:)
    func endSaveWindowsStateAsDICOMSR(_ sender: Any!) {
        ViewerWorkspaceArchiver(processGraph: sessionGraph.processGraph).endNaming(in: self, tag: ViewerSender.tag(sender))
    }

    /// Saves the layout, archived as a DICOM SR when the preference asks for it.
    @objc(saveWindowsState)
    class func saveWindowsState() {
        ViewerWorkspaceArchiver(processGraph: processGraph).save()
    }

    /// Saves the layout of the displayed viewers into each study they show.
    @objc(saveWindowsStateWithDICOMSR:name:)
    class func saveWindowsState(withDICOMSR DICOMSR: Bool, name: String?) {
        ViewerWorkspaceArchiver(processGraph: processGraph).save(asDICOMSR: DICOMSR, name: name)
    }
}
