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

// The exported names of OSIROIManager's notification and its keys, which
// OSIROIManager.swift uses and plugins link, OSILineROIType, and the -init of
// NSObject.

#import "OSIROIManager.h"

__attribute__((used)) NSString* const OSIROIManagerROIsDidUpdateNotification = @"OSIROIManagerROIsDidUpdateNotification";

__attribute__((used)) NSString* const OSIROIUpdatedROIKey = @"OSIROIUpdatedROIKey";
__attribute__((used)) NSString* const OSIROIRemovedROIKey = @"OSIROIRemovedROIKey";
__attribute__((used)) NSString* const OSIROIAddedROIKey = @"OSIROIAddedROIKey";

// Declared by OSIROIManager.h since OsiriX and never defined, so a plugin that
// named it did not link; it is defined here with its own name as its value.
__attribute__((used)) const NSString *OSILineROIType = @"OSILineROIType";

// The former class did not override -init: NSObject's made a manager with no
// volume window and nil lists. The Swift class declares its own designated
// initializer, and the stub Swift emits for -init would stop the app; this
// one runs NSObject's, which leaves the stored properties zero (nil, NO) as
// the ivars were.
@implementation OSIROIManager (HorosInit)

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
#pragma clang diagnostic ignored "-Wobjc-designated-initializers"
- (id)init
{
    return [super init];
}
#pragma clang diagnostic pop

@end
