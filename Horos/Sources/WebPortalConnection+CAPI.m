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

// The part of WebPortalConnection that Swift cannot write. The class is
// implemented in Swift since #718 (WebPortalConnection.swift); it subclasses
// HTTPConnection, which stays Objective-C:
// - Swift cannot read the instance variables of an Objective-C class, so this
//   category on HTTPConnection answers the socket, the server and the request
//   message the former -asyncSocket, -server and -request returned;
// - N2LogStackTrace is a C variadic function, which Swift cannot call.

#import "HTTPConnection.h"
#import "N2Debug.h"

@interface HTTPConnection (WebPortalConnectionInstanceVariables)
-(AsyncSocket*)webPortalConnectionAsyncSocket;
-(HTTPServer*)webPortalConnectionServer;
-(CFHTTPMessageRef)webPortalConnectionRequest CF_RETURNS_NOT_RETAINED;
@end

__attribute__((visibility("hidden"))) void WebPortalConnectionLogStackTrace(NSString* message);

@implementation HTTPConnection (WebPortalConnectionInstanceVariables)

-(AsyncSocket*)webPortalConnectionAsyncSocket {
	return asyncSocket;
}

-(HTTPServer*)webPortalConnectionServer {
	return server;
}

-(CFHTTPMessageRef)webPortalConnectionRequest {
	return request;
}

@end

__attribute__((visibility("hidden"))) void WebPortalConnectionLogStackTrace(NSString* message)
{
	N2LogStackTrace(@"%@", message);
}
