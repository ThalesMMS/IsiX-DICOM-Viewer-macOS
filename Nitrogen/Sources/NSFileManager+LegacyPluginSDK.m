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

#import "NSFileManager+N2.h"

// The Folder Manager and FSRef are deprecated and have no replacement that
// takes the same arguments: these two methods exist for the plugins built for
// Horos and OsiriX that still send them, which are not rebuilt.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

@implementation NSFileManager (N2)

-(NSString*)findSystemFolderOfType:(int)folderType forDomain:(int)domain {
    FSRef folder;
    NSString* result = nil;

    OSErr err = FSFindFolder(domain, folderType, kCreateFolder, &folder);
    if (err == noErr) {
        CFURLRef url = CFURLCreateFromFSRef(kCFAllocatorDefault, &folder);
        result = [[[(NSURL*)url path] retain] autorelease];
        if (url) CFRelease(url);
    } else [NSException raise:NSGenericException format:@"FSFindFolder error %d", err];

    return result;
}

// The size of what the reference names, by its path (-sizeAtPath:).
-(NSUInteger)sizeAtFSRef:(FSRef*)theFileRef {
    if (!theFileRef) return 0;
    CFURLRef url = CFURLCreateFromFSRef(kCFAllocatorDefault, theFileRef);
    if (!url) return 0;
    NSUInteger size = [self sizeAtPath:[(NSURL*)url path]];
    CFRelease(url);
    return size;
}

@end

#pragma clang diagnostic pop
