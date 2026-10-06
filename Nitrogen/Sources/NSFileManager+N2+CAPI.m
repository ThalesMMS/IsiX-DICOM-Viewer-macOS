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

// The part of NSFileManager (N2) that stays in Objective-C; the rest is
// implemented in Swift (Nitrogen/Sources/NSFileManager+N2.swift).
// These four methods use FSRef and the File Manager, which Swift does not
// see. They are unchanged.

#import "NSFileManager+N2.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
#pragma clang diagnostic ignored "-Wdeprecated-implementations"
// As Objective-C, not C++, the const ItemCount of -sizeAtFSRef: sizes its
// arrays by a folded constant: the same arrays.
#pragma clang diagnostic ignored "-Wgnu-folding-constant"
@implementation NSFileManager (N2)

-(NSString*)findSystemFolderOfType:(int)folderType forDomain:(int)domain {
    FSRef folder;
    NSString* result = NULL;
	
    OSErr err = FSFindFolder(domain, folderType, kCreateFolder, &folder);
    if (err == noErr) {
        CFURLRef url = CFURLCreateFromFSRef(kCFAllocatorDefault, &folder);
        result = [(NSURL*)url path];
		CFRelease(url);
    } else [NSException raise:NSGenericException format:@"FSFindFolder error %d", err];
	
    return result;
}

-(NSUInteger)sizeAtPath:(NSString*)path {
	FSRef fsRef;
	CFURLGetFSRef((CFURLRef)[NSURL fileURLWithPath:path], &fsRef);
	return [self sizeAtFSRef:&fsRef];
}

-(NSUInteger)sizeAtFSRef:(FSRef*)theFileRef {
	FSIterator thisDirEnum = NULL;
	NSUInteger totalSize = 0;
	
	NSMutableArray* fsRefs = [NSMutableArray arrayWithCapacity:1];
	[fsRefs addObject:[NSData dataWithBytes:theFileRef length:sizeof(FSRef)]];

	@try {
		while (fsRefs.count) {
			NSData* d = [[fsRefs objectAtIndex:0] retain];
			[fsRefs removeObjectAtIndex:0];
			FSRef currFsRef;
			[d getBytes:&currFsRef length:sizeof(FSRef)];
			[d release];
			
			FSCatalogInfo fetchedInfos;
			//HFSUniStr255 outName;
			OSErr fsErr = FSGetCatalogInfo(&currFsRef, kFSCatInfoDataSizes|kFSCatInfoRsrcSizes|kFSCatInfoNodeFlags, &fetchedInfos, NULL, NULL, NULL);
			//NSLog(@"ok for %@", [NSString stringWithCharacters:outName.unicode length:outName.length]);
			
			if (fsErr == noErr)
				if (fetchedInfos.nodeFlags&kFSNodeIsDirectoryMask) {
					if (FSOpenIterator(&currFsRef, kFSIterateFlat, &thisDirEnum) == noErr) {
						const ItemCount kMaxEntriesPerFetch = 256;
						ItemCount actualFetched;
						FSRef fetchedRefs[kMaxEntriesPerFetch];
						FSCatalogInfo fetchedInfos[kMaxEntriesPerFetch];
						
						OSErr fsErr = FSGetCatalogInfoBulk(thisDirEnum, kMaxEntriesPerFetch, &actualFetched, NULL, kFSCatInfoDataSizes|kFSCatInfoRsrcSizes|kFSCatInfoNodeFlags, fetchedInfos, fetchedRefs, NULL, NULL);
						while ((fsErr == noErr) || (fsErr == errFSNoMoreItems)) {
							for (ItemCount thisIndex = 0; thisIndex < actualFetched; ++thisIndex)
								[fsRefs addObject:[NSData dataWithBytes:&fetchedRefs[thisIndex] length:sizeof(FSRef)]];
							if (fsErr == errFSNoMoreItems)
								break;
							fsErr = FSGetCatalogInfoBulk(thisDirEnum, kMaxEntriesPerFetch, &actualFetched, NULL, kFSCatInfoDataSizes|kFSCatInfoRsrcSizes|kFSCatInfoNodeFlags, fetchedInfos, fetchedRefs, NULL, NULL);
						}
						
						FSCloseIterator(thisDirEnum);
					}
				} else {
					totalSize += fetchedInfos.dataLogicalSize;
					totalSize += fetchedInfos.rsrcLogicalSize;
				}
			else
				NSLog(@"[NSFileManager sizeAtFSRef:] error: %d", fsErr);
		}
		
	} @catch (NSException* e) {
		NSLog(@"[NSFileManager sizeAtFSRef:] error: %@", e.description);
	}

	return totalSize;
}

-(NSString*)destinationOfAliasAtPath:(NSString*)inPath {
    if (inPath == nil)
        return nil;
    
	CFStringRef resolvedPath = nil;
    
	CFURLRef url = CFURLCreateWithFileSystemPath(nil /*allocator*/, (CFStringRef)inPath, kCFURLPOSIXPathStyle, NO /*isDirectory*/);
	if (url != nil) {
		FSRef fsRef;
		if (CFURLGetFSRef(url, &fsRef))
		{
			Boolean targetIsFolder, wasAliased;
			if (FSResolveAliasFile (&fsRef, true /*resolveAliasChains*/, &targetIsFolder, &wasAliased) == noErr && wasAliased)
			{
				CFURLRef resolvedurl = CFURLCreateFromFSRef(nil /*allocator*/, &fsRef);
				if (resolvedurl != nil)
				{
					resolvedPath = CFURLCopyFileSystemPath(resolvedurl, kCFURLPOSIXPathStyle);
					CFRelease(resolvedurl);
				}
			}
		}
		CFRelease(url);
	}
    
	return [(NSString*)resolvedPath autorelease];	
}

@end
#pragma clang diagnostic pop
