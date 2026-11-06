/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, ?version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ?See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ?If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: ? OsiriX
 ?Copyright (c) OsiriX Team
 ?All rights reserved.
 ?Distributed under GNU - LGPL
 ?
 ?See http://www.osirix-viewer.com/copyright.html for details.
 ? ? This software is distributed WITHOUT ANY WARRANTY; without even
 ? ? the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 ? ? PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

// The part of VRView that stays in Objective-C. The class is implemented in
// Swift (VRView.swift and its extensions). Here are:
// - the historical dragging-source selector -draggingSourceOperationMaskForLocal:,
//   which VRView.h declares for plugins and which Swift cannot declare (AppKit
//   marks it unavailable); it answers the session's mask;
// - the adoption of HorosMPRVRViewMessages (MPRHostMessages.h), the messages
//   the Swift MPR sends the VRView of its hidden VRController: a Swift
//   conformance would make those main-actor methods public requirements of a
//   nonisolated protocol; adopted here, as before, the MPR's casts find it at
//   run time and each message is the class's own;
// - the VTK adapter's protocols adopted by what it draws with
//   (VTKAdapterDrawing.h): the 3D views' Metal presenter and the ROI canvas.

#import "VRView.h"
#import "Horos-Swift.h"
#import "VTKAdapterDrawing.h"
#import "MPRHostMessages.h"

@implementation VRView (LegacyDraggingSourceCompatibility)

- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal
{
    return [self horosSourceOperationMask];
}

@end

@interface VRView (HorosMPRVRViewMessages) <HorosMPRVRViewMessages>
@end

@implementation VRView (HorosMPRVRViewMessages)
@end

// What the VTK adapter draws with (VTKAdapterDrawing.h).
@implementation HorosVRPresenter (IsiXVTKFramePresenter)
@end

@implementation HorosROICanvas (IsiXVTKLineCanvas)
@end
