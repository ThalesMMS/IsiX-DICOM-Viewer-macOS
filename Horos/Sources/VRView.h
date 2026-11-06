/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/

// VRView is implemented in Swift: VRView.swift (the class, its state, its
// life and its accessors) and its extensions VRView+<part>.swift, one per
// responsibility. This header keeps <Horos/VRView.h>: it brings in the
// generated interface, which declares the class under the same name and
// selectors, and declares what Swift cannot, implemented in VRView+CAPI.m.

#import <AppKit/AppKit.h>

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class VRView;
#else
#import "Horos-Swift.h"

// The former header declared -dealloc, which Swift cannot declare (its deinit
// is -dealloc). The method is the one every object has.
@interface VRView (VRViewDealloc)
- (void) dealloc;
@end

// Preserve the historical plugin selector through the current dragging-source operation.
@interface VRView (LegacyDraggingSourceCompatibility)
- (NSDragOperation)draggingSourceOperationMaskForLocal:(BOOL)isLocal;
@end
#endif
