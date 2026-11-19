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
/*=========================================================================
 Program:   OsiriX

 Copyright (c) Pixmeo
 All rights reserved.
 =========================================================================*/

#ifndef _VTKVIEW_H_INCLUDED_
#define _VTKVIEW_H_INCLUDED_

#import <AppKit/AppKit.h>

/** \brief View for using VTK

The class the 3D views descend from in the plugin SDK of Horos and OsiriX.
There it was a vtkCocoaGLView, the OpenGL view of VTK, and made a renderer, a
render window and an interactor of its own. The application draws its 3D views
with Metal and has no such view: the class is an NSView, and a view of this
class alone has no VTK object. The 3D views of the application (VRView, and
HorosSceneView for the surface and ROI volume views) override -renderer,
-renderWindow and -prepareForRelease with what they do, and HorosSceneView
-removeAllActors too. The class overrides no drawing, event, layer or tracking
area method of NSView, and -initWithFrame: makes the view that NSView's makes.

The SDK declared the VTK objects by their C++ types (vtkRenderer *,
vtkRenderWindow *, vtkCocoaRenderWindow *). They are void * here, of the same
size and passed the same way, so that this header needs no header of VTK.

VTKView.swift implements the class (@objc @implementation): the runtime has an
Objective-C class of this name, which a plugin's subclass can inherit from.
*/
@interface VTKView : NSView

/// The megabytes of memory the graphics of the main display may use, whatever
/// the display asked for: the SDK answered for one graphics card too.
+ (unsigned long) VRAMSizeForDisplayID: (CGDirectDisplayID) displayID NS_SWIFT_NONISOLATED;

// Access to VTK instances: NULL in a view of this class alone
-(void *)renderer;
-(void *)renderWindow;
-(void *) cocoaWindow;
-(void)removeAllActors;
-(void) prepareForRelease;

- (void)initializeVTKSupport;
- (void)cleanUpVTKSupport;

// Accessors
- (void)setRenderer:(void *)theRenderer;

@end

#endif
