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

// The HTTP server of the Horos and OsiriX plugin SDK (cocoahttpserver): a
// listener that makes one connection object, of its connection class, for
// each connection accepted, and publishes itself with Bonjour when it has a
// type. HTTPServer.swift implements the class (@objc @implementation), so
// that the runtime has an Objective-C class of this name that a plugin built
// for either SDK can name, make and subclass; the web portal's server
// (WebPortalServer) is a subclass. It has the instance variables the SDK
// declared, which a subclass of a plugin reads and writes directly; that of
// the listening socket stays nil.
//
// The listener is SwiftNIO's, and a connection's socket is the AsyncSocket
// that wraps its channel. A server that implements the AsyncSocket delegate
// method -onSocket:wantsRunLoopForNewSocket: is asked, as it was, for the run
// loop each new connection runs on, and refuses the connection when it
// answers nil; the connections of a server that does not implement it run on
// one thread the application keeps for them.

#import <Foundation/Foundation.h>

@class AsyncSocket;


@interface HTTPServer : NSObject <NSNetServiceDelegate>

- (id)delegate;
- (void)setDelegate:(id)newDelegate;

- (NSURL *)documentRoot;
- (void)setDocumentRoot:(NSURL *)value;

- (Class)connectionClass;
- (void)setConnectionClass:(Class)value;

- (NSString *)domain;
- (void)setDomain:(NSString *)value;

- (NSString *)type;
- (void)setType:(NSString *)value;

- (NSString *)name;
- (NSString *)publishedName;
- (void)setName:(NSString *)value;

- (UInt16)port;
- (void)setPort:(UInt16)value;

- (NSDictionary *)TXTRecordDictionary;
- (void)setTXTRecordDictionary:(NSDictionary *)dict;

- (BOOL)start:(NSError **)errPtr;
- (BOOL)stop;

- (uint)numberOfHTTPConnections;

- (void)connectionDidDie:(NSNotification *)notification;

@end
