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



/********** 
Super Class for SCU classes such as verifySCU, storeSCU, moveSCU, findSCU
**********/

#import <Cocoa/Cocoa.h>

/** \brief  Base Class for SCU classes such as verifySCU, storeSCU, moveSCU, findSCU 
*
* SCU classes are usually outgoing connections
* based on DCMTK 
*
* The class of the Horos and OsiriX plugin SDK the query nodes and the print
* SCU inherit from: a plugin built for either looks it up by name, and may
* subclass it. It keeps the peer it was made for (the two AE titles, the host
* and port, the transfer syntax, the compression and the node's other
* settings) and the flag that gives up the association in progress, which any
* thread may set.
*
* The SDK declared one more message with DCMTK's C++ types, which this header
* leaves out so that it carries no C++:
* -addPresentationContext:abstractSyntax:, taking a T_ASC_Parameters * and
* answering an OFCondition. A plugin built with DCMTK's headers still sends
* it; the class answers it in the DCMTK adapter.
*
* DCMTKServiceClassUser.swift implements the class (@objc @implementation),
* with the instance variables the SDK declared, which a subclass of a plugin
* reads and writes directly: those of the peer and the abort flag are what the
* class keeps, and those of the association it no longer makes itself (the
* network and TLS settings) stay zero and nil.
*/
@interface DCMTKServiceClassUser : NSObject

@property BOOL _abortAssociation;
@property (readonly) NSString *_hostname;
@property int _port;

- (id) initWithCallingAET:(NSString *)myAET  
			calledAET:(NSString *)theirAET  
			hostname:(NSString *)hostname 
			port:(int)port 
			transferSyntax:(int)transferSyntax
			compression: (float)compression
			extraParameters:(NSDictionary *)extraParameters;
			
- (NSString *)calledAET;
- (NSString *)callingAET;
- (NSDictionary *) extraParameters;
@end
