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


#import <Cocoa/Cocoa.h>

/** \brief Plugin for adding file format

The base class of the principal class of a file-format plugin, and the messages
DicomFile and DCMPix send to it. A plugin built for Horos or OsiriX subclasses
it in Objective-C, sets the instance variables the former SDK declared here
(_height, _width, _rowBytes, _fImage, _isRGB and the others) directly in
-checkLoadAtPath:, and inherits the methods that answer them.

PluginFileFormatDecoder.swift implements the class (@objc @implementation), so
the runtime sees an Objective-C class of this name that such a subclass can
inherit from. Its instance variables are Swift stored properties of the same
names; the linker exports their offsets under the _OBJC_IVAR_$_ names the
plugin's binary looks up (Horos/Scripts/Horos/legacy-plugin-ivar-aliases.rsp).
*/
@interface PluginFileFormatDecoder : NSObject

// not used currently
+ (float *)decodedDataAtPath:(NSString *)path;

/*
	This is the main method to get the fImage float pointer used by DCMPix to create an image.
	If the data is RGB the pointe should be to unsigned char with the format ARGB
	Grayscale data is a float pointer
*/

- (float *)checkLoadAtPath:(NSString *)path;

//returns values needed by DCMPix
- (NSNumber *)height;
- (NSNumber *)width;
- (NSNumber *)rowBytes;
- (NSNumber *)windowWidth; //optional
- (NSNumber *)windowLevel; //optional
- (BOOL)isRGB; //default is YES

// Optional values for loading into the DB.
- (NSString *)patientName;
- (NSString *)patientID;
- (NSString *)studyID;
- (NSString *)seriesID;
- (NSString *)imageID;
- (NSString *)studyDescription;
- (NSString *)seriesDescription;

@end
