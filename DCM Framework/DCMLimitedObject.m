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


#import "DCMLimitedObject.h"
#import "DCM.h"
#import "DCMHostServices.h"

// The host's DCMTK reader reads the file up to `lastGroup` (#742); what comes
// back is its object, which answers the DCMObject messages, not a DCMLimitedObject.
static Class DCMLimitedHostReader(void)
{
	Class reader = NSClassFromString(@"HorosDCMTKObject");
	return [reader respondsToSelector: @selector(objectWithData:transferSyntax:decodingPixelData:lastGroup:)] ? reader : nil;
}

@implementation DCMLimitedObject
+ (id)objectWithData:(NSData *)data lastGroup:(unsigned short)lastGroup{
	return [[[DCMLimitedObject alloc] initWithData:data lastGroup:(unsigned short)lastGroup] autorelease];
}

+ (id)objectWithContentsOfFile:(NSString *)file lastGroup:(unsigned short)lastGroup{
	return [[[DCMLimitedObject alloc] initWithContentsOfFile:file lastGroup:(unsigned short)lastGroup] autorelease];
}

+ (id)objectWithContentsOfURL:(NSURL *)aURL lastGroup:(unsigned short)lastGroup{
	return [[[DCMLimitedObject alloc] initWithContentsOfURL:(NSURL *)aURL lastGroup:(unsigned short)lastGroup] autorelease];
}

- (id)initWithData:(NSData *)data lastGroup:(unsigned short)lastGroup{
	[self release];
	return [[DCMLimitedHostReader() objectWithData: data transferSyntax: nil decodingPixelData: NO lastGroup: lastGroup] retain];
}

- (id)initWithContentsOfFile:(NSString *)file lastGroup:(unsigned short)lastGroup{
	[self release];
	if ([[NSFileManager defaultManager] fileExistsAtPath: file] == NO) return nil;
	return [[DCMLimitedHostReader() objectWithContentsOfFile: file decodingPixelData: NO lastGroup: lastGroup] retain];
}

- (id)initWithContentsOfURL:(NSURL *)aURL lastGroup:(unsigned short)lastGroup{
	if ([aURL isFileURL])
		return [self initWithContentsOfFile: [aURL path] lastGroup: lastGroup];
	NSData *aData = [NSData dataWithContentsOfURL:aURL];
	return [self initWithData:aData lastGroup:(unsigned short)lastGroup] ;
}

@end
