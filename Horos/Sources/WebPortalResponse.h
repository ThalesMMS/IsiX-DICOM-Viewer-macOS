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

// WebPortalResponse, WebPortalProxy, WebPortalProxyObjectTransformer and its
// subclasses, and NSMutableDictionary (WebPortalProxy) are implemented in Swift
// (Horos/Sources/WebPortalResponse.swift). This header keeps
// <Horos/WebPortalResponse.h>: it brings in the generated interface, which
// declares the same class names and selectors. iPhoneCompatibleNumericalFormat
// and the accessors below stay in Objective-C, in WebPortalResponse+CAPI.mm.

#import "HTTPResponse.h"

@class WebPortalConnection, WebPortalSession, WebPortal;

// HTTPDataResponse's `data` instance variable, which it sends: Swift cannot
// reach an instance variable, and WebPortalResponse's `data` property keeps
// its value there, as the former class did (WebPortalResponse+CAPI.mm).
@interface HTTPDataResponse (WebPortalResponseData)

-(NSData*)webPortalResponseData;
-(void)setWebPortalResponseData:(NSData*)data;

@end

#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the classes themselves: headers it imports may only name them.
@class WebPortalResponse, WebPortalProxy, WebPortalProxyObjectTransformer, InfoTransformer, StringTransformer, DateTransformer, DicomStudyTransformer, DicomSeriesTransformer, WebPortalUserTransformer;
#else
#import "Horos-Swift.h"

// The former `httpHeaders` property, implemented in WebPortalResponse+CAPI.mm.
// HTTPDataResponse's HTTPResponse conformance declares -httpHeaders with
// another type, which Swift cannot redeclare: Swift calls the dictionary
// `mutableHTTPHeaders`, and this category keeps -httpHeaders for
// Objective-C code and plugins.
@interface WebPortalResponse (HTTPHeaders)

@property(readonly) NSMutableDictionary* httpHeaders;

@end
#endif
