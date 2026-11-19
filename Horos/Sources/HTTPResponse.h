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

// The response classes of the HTTP server of the Horos and OsiriX plugin SDK
// (cocoahttpserver). HTTPDataResponse.swift and HTTPFileResponse.swift
// implement them (@objc @implementation), so that the runtime has Objective-C
// classes of these names: a plugin built for either SDK names them, makes
// them and may subclass them. They have the instance variables the SDK
// declared, which a subclass of a plugin reads and writes directly.
//
// The protocol declares what the SDK declared as methods as properties of
// the same types: the selectors are the same (-contentLength, -offset,
// -setOffset:, -isDone), and the application's Swift reads them as it reads
// the bodies of its own responses.

#import <Foundation/Foundation.h>


@protocol HTTPResponse

// Returns the length of the data in bytes.
// If you don't know the length in advance, implement the iChunked method and have it return YES.
@property (readonly) UInt64 contentLength;

@property UInt64 offset;

- (NSData *)readDataOfLength:(unsigned int)length;

// Should only return YES after the HTTPConnection has read all available data.
@property (readonly) BOOL isDone;

#if !defined(__swift__)
// The connection asks a response for these by name, when it answers them. They
// are declared for Objective-C only: the application's own responses answer
// some of them with other types (a mutable dictionary of header fields).

@optional

// If you want to add any extra HTTP headers to the response,
// simply return them in a dictionary in this method.
- (NSDictionary *)httpHeaders;

// If you want to generate your response asynchronously (e.g. in a background thread),
// implement this method in your custom response class and return YES.
// As you generate the data, call HTTPConnection's responseHasAvailableData method.
//
// Important: You should read the discussion at the bottom of this header.
- (BOOL)isAsynchronous;

// This method is called from the HTTPConnection when the connection is closed,
// or when the connection is finished with the response.
// If your response is asynchronous, you should implement this method so you can be sure not to
// invoke HTTPConnection's responseHasAvailableData method after this method is called.
- (void)connectionDidClose;

// If you don't know the content-length in advance,
// implement this method in your custom response class and return YES.
//
// Important: You should read the discussion at the bottom of this header.
- (BOOL)isChunked;

- (int)statusCode;

#endif

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// A file, read as it is sent. Its length is that of the file opened, which
// for a symbolic link is its target's.
@interface HTTPFileResponse : NSObject <HTTPResponse>

- (id)initWithFilePath:(NSString *)filePath;
- (NSString *)filePath;

@property (readonly) UInt64 contentLength;
@property UInt64 offset;
- (NSData *)readDataOfLength:(unsigned int)length;
@property (readonly) BOOL isDone;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@interface HTTPDataResponse : NSObject <HTTPResponse>

- (id)initWithData:(NSData *)data;

@property (readonly) UInt64 contentLength;
@property UInt64 offset;
- (NSData *)readDataOfLength:(unsigned int)length;
@property (readonly) BOOL isDone;

@end

// Important notice to those implementing custom asynchronous and/or chunked responses:
//
// HTTPConnection supports asynchronous responses.  All you have to do in your custom response class is
// asynchronously generate the response, and invoke HTTPConnection's responseHasAvailableData method.
// You don't have to wait until you have all of the response ready to invoke this method.  For example, if you
// generate the response in incremental chunks, you could call responseHasAvailableData after generating
// each chunk.  You MUST invoke the responseHasAvailableData method on the proper thread/runloop.  That is,
// the thread/runloop that the HTTPConnection is operating in.
//
// With an asynchronous response, when HTTPConnection calls your readDataOfLength method, you may or may not
// have any available data.  If you don't, then simply return nil.
// You should later invoke HTTPConnection's responseHasAvailableData when you have data to send.
//
// It's important that you also keep in mind that the HTTP server supports range requests.
// The setOffset method is mandatory, and should not be ignored.
// Make sure you take into account the offset within the readDataOfLength method.
//
// If you don't know the content-length in advanced, you should also implement the isChunked method.
// This means the response will not include a Content-Length header, and will instead use "Transfer-Encoding: chunked".
// There's a good chance that if your response is asynchronous, it's also chunked.
