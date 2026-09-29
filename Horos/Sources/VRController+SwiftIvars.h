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

// What the Swift subclass of VRController (EndoscopyVRController) reads and
// writes of the class that stays Objective-C. Swift cannot see instance
// variables, so the ones the former Objective-C subclass used directly are
// reached through these accessors, implemented in VRController+SwiftIvars.m.
// This header is for the bridging header only: it is not part of the SDK.
// (VRController.h completes its interface before it brings in Horos-Swift.h,
// so this category compiles wherever the bridging header is read.)

#import "VRController.h"

@interface VRController (SwiftIvars)

/// shadingsPresetsController, the nib's array controller of the shading presets.
@property(readonly, nullable) ShadingArrayController *horos_shadingsPresetsController;
/// shadingCheck and shadingValues, the nib's shading switch and text.
@property(readonly, nullable) NSButton *horos_shadingCheck;
@property(readonly, nullable) NSTextField *horos_shadingValues;
/// FTAdapter, assigned without a retain, as the former subclass did after
/// releasing the adapter it made (the fly-thru controller retains it).
@property(assign, nullable) VRFlyThruAdapter *horos_FTAdapter;

@end
