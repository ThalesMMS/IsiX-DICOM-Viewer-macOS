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

// A connection of the HTTP server of the Horos and OsiriX plugin SDK
// (cocoahttpserver). HTTPConnection.swift implements the class
// (@objc @implementation), so that the runtime has an Objective-C class of
// this name that a plugin built for either SDK can name and subclass; the web
// portal's connection (WebPortalConnection) is a subclass. It has the instance
// variables the SDK declared, which a subclass of a plugin reads and writes
// directly; those of the request being read and of the answer being sent stay
// nil and zero.
//
// The HTTP exchange itself (reading the request, its body in pieces, ranges,
// keep-alive) is the application's, over SwiftNIO; it asks the connection, by
// these selectors and on the connection's own thread, what the SDK's
// connection asked itself: whether a method is served, what answers a
// request, whether a path is protected, and what to answer when it cannot
// serve. By itself the class serves GET and HEAD of the files under its
// server's document root, without a password.
//
// What differs from the SDK:
// - TLS belongs to the listener: -isSecureServer and
//   -sslIdentityAndCertificates are not asked.
// - Which methods carry a request body is decided before the connection's
//   thread is asked: -expectsRequestBodyFromMethod:atPath: answers the rule
//   (POST and PUT) and an override of it is not asked.
// - The class has no password check of its own: -isAuthenticated answers NO,
//   so a path that -isPasswordProtected: protects answers 401 unless a subclass
//   overrides -isAuthenticated; -passwordForUser:,
//   -useDigestAccessAuthentication and -realm are answered and not used.
// - -filePathForURI: answers the path of a regular file inside the document
//   root, links resolved, and nil for anything else, a file that does not exist
//   included.

#import <Foundation/Foundation.h>


#if TARGET_OS_IPHONE
// Note: You may need to add the CFNetwork Framework to your project
#import <CFNetwork/CFNetwork.h>
#endif


@class AsyncSocket;
@class HTTPServer;
@protocol HTTPResponse;


#define HTTPConnectionDidDieNotification  @"HTTPConnectionDidDie"

@interface HTTPConnection : NSObject

- (id)initWithAsyncSocket:(AsyncSocket *)newSocket forServer:(HTTPServer *)myServer;

- (BOOL)supportsMethod:(NSString *)method atPath:(NSString *)path;
- (BOOL)expectsRequestBodyFromMethod:(NSString *)method atPath:(NSString *)relativePath;

- (BOOL)isSecureServer;
- (NSArray *)sslIdentityAndCertificates;

- (BOOL)isPasswordProtected:(NSString *)path;
- (BOOL)useDigestAccessAuthentication;
- (NSString *)realm;
- (NSString *)passwordForUser:(NSString *)username;

- (NSString *)filePathForURI:(NSString *)path;

- (NSObject<HTTPResponse> *)httpResponseForMethod:(NSString *)method URI:(NSString *)path;

- (void)prepareForBodyWithSize:(UInt64)contentLength;
- (void)processDataChunk:(NSData *)postDataChunk;

- (void)handleVersionNotSupported:(NSString *)version;
- (void)handleAuthenticationFailed;
- (void)handleResourceNotFound;
- (void)handleInvalidRequest:(NSData *)data;
- (void)handleUnknownMethod:(NSString *)method;

- (NSData *)preprocessResponse:(CFHTTPMessageRef)response;
- (NSData *)preprocessErrorResponse:(CFHTTPMessageRef)response;

- (void)die;

// The SDK's header did not declare these two and its class implemented them:
// the exchange asks the connection whether the request is authenticated, and
// tells it to answer a request once it is complete. A subclass overrides them,
// as the web portal's connection does.
- (BOOL)isAuthenticated;
- (void)replyToHTTPRequest;

// The SDK declared this one in a category, HTTPConnection
// (AsynchronousHTTPResponse): a response that answered that it had no data
// yet has some now.
- (void)responseHasAvailableData;

@end
