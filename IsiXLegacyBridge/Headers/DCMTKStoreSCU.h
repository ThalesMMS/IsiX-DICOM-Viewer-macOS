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
// DCMTKStoreSCU of the legacy plugin SDK, kept by IsiXLegacyBridge: a send
// through the plugin API (IsiXNetwork). The called AE title, address and port
// must be those of a node the user configured in Locations with Send on; the
// application opens the association, with the node's transfer syntax and TLS.

#import "IsiXLegacyBridgeDefines.h"

ISIX_LEGACY_CLASS(DCMTKStoreSCU)
@interface IsiXLegacyDCMTKStoreSCU : NSObject

+ (int) sendSyntaxForListenerSyntax: (int) listenerSyntax;

- (id) initWithCallingAET: (NSString*) myAET
                calledAET: (NSString*) theirAET
                 hostname: (NSString*) hostname
                     port: (int) port
              filesToSend: (NSArray*) filesToSend
           transferSyntax: (int) transferSyntax
              compression: (float) compression
          extraParameters: (NSDictionary*) extraParameters;

/// Sends, and returns when the node answered every file. Raises an
/// NSException, as it did, when the node is not configured or files were not sent.
- (void) run: (NSOperation*) operation;
- (void) updateLogEntry: (NSMutableDictionary*) userInfo;

@end

@compatibility_alias DCMTKStoreSCU IsiXLegacyDCMTKStoreSCU;
