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

#import <Cocoa/Cocoa.h>

// The parts of a URL as -[NSURL parts] reads them from the URL's text and
// +[NSURL URLWithParts:] writes them back. NSURL+N2.swift implements the class
// (@objc @implementation), so that the runtime sees an Objective-C class of
// this name, which a plugin built for Horos or OsiriX looks up when it loads.
@interface N2URLParts : NSObject

@property(retain) NSString *protocol, *address, *port, *path, *params;
@property(readonly) NSString* pathAndParams;

@end

// NSURL (N2) is implemented in Swift (NSURL+N2.swift), which declares the
// selectors of the SDK's category:
//
//     -(N2URLParts*)parts;
//     +(NSURL*)URLWithParts:(N2URLParts*)parts;
//
// Objective-C reads them from the generated interface.
#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extension itself.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#endif
