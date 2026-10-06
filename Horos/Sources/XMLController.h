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

// XMLController, the window of a file's DICOM (or other) meta-data, is
// implemented in Swift (Horos/Sources/XMLController.swift). This
// header keeps <Horos/XMLController.h>: it brings in the generated interface,
// which declares the same class name and selectors.
// Its superclass, OSIWindowController, stays in Objective-C, and so does the
// DCMTK part, XMLControllerDCMTKCategory.

#import <Cocoa/Cocoa.h>
#import "OSIWindowController.h"

@class ViewerController;
@class DCMObject;

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the class itself: headers it imports may only name it.
@class XMLController;

// XML_from_FVTiff() of FVTiff.h, whose VTK TIFF header Swift does not read;
// in XMLController+CAPI.m. The document is returned retained, as XML_from_FVTiff
// returns it.
NSXMLDocument* XMLControllerCAPIXMLFromFVTiff(NSString* srcFile) NS_RETURNS_RETAINED;

// Swift cannot see a category of its own class, and XMLControllerDCMTKCategory.h
// declares one: XMLController+CAPI.m sends the category's messages for it.
BOOL XMLControllerCAPIModifyDicom(NSArray* tagAndValues, NSArray* dicomFiles, NSArray** reasons);
void XMLControllerCAPIPrepareDictionaryArray(XMLController* controller);
int XMLControllerCAPIGetGroupAndElementForName(XMLController* controller, NSString* name, int* gp, int* el);
#else
#import "Horos-Swift.h"
#endif
