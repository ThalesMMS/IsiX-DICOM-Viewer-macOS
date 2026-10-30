/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)

 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation,  version 3 of the License.

 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.

 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE.  See the
 GNU Lesser General Public License for more details.

 You should have received a copy of the GNU Lesser General Public License
 along with Horos.  If not, see http://www.gnu.org/licenses/lgpl.html

 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program:   OsiriX
  Copyright (c) OsiriX Team
  All rights reserved.
  Distributed under GNU - LGPL

  See http://www.osirix-viewer.com/copyright.html for details.
     This software is distributed WITHOUT ANY WARRANTY; without even
     the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
     PURPOSE.
 ============================================================================*/
//
// SendController of the legacy plugin SDK, kept by IsiXLegacyBridge: a send
// of images of the database, or of DICOM files, to a node the user configured
// with Send on, through the plugin API (IsiXNetwork). The send runs in the
// background, as it did; the plugin cannot name a node of its own.

#import "IsiXLegacyBridgeDefines.h"

ISIX_LEGACY_CLASS(SendController)
@interface IsiXLegacySendController : NSObject

/// Asks the user which configured node to send to, then sends. `files`:
/// DicomImage objects or paths of DICOM files.
+ (void) sendFiles: (NSArray*) files;
/// `node`: one of DCMNetServiceDelegate's dictionaries.
+ (void) sendFiles: (NSArray*) files toNode: (NSDictionary*) node;
/// The node's own transfer syntax is used; `syntax` is accepted and ignored.
+ (void) sendFiles: (NSArray*) files toNode: (NSDictionary*) node usingSyntax: (int) syntax;
+ (int) sendControllerObjects;

@end

@compatibility_alias SendController IsiXLegacySendController;
