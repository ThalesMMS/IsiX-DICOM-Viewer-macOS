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


#import <Cocoa/Cocoa.h>

extern NSString* N2ConnectionListenerOpenedConnectionNotification;
extern NSString* N2ConnectionListenerOpenedConnection;

@class N2Connection;

// The listener of the plugin SDK of Horos and OsiriX: it accepted TCP, or
// local, connections and made an object of the connection class for each.
//
// The sockets it listened on left the application with the stream transport
// of N2Connection: -initWithPort:connectionClass: and
// -initWithPath:connectionClass: answer nil, as they did for a port or a path
// that could not be bound, and nothing listens.
//
// N2ConnectionListener.swift implements the class (@objc @implementation).
@interface N2ConnectionListener : NSObject

@property BOOL threadPerConnection;

- (id)initWithPort:(NSInteger)port connectionClass:(Class)classs;
- (id)initWithPath:(NSString*)path connectionClass:(Class)classs;

- (in_port_t)port;

// What the SDK's class implemented and its header did not declare.
- (void)handleNewConnectionFromAddress:(NSData*)addr inputStream:(NSInputStream*)istr outputStream:(NSOutputStream*)ostr;
- (void)_threadHandleNewConnection:(NSArray*)args;
- (void)connectionStatusDidChange:(NSNotification*)notification;

// What a later release of the application added to the class.
- (id)initWithPort:(NSInteger)port loopbackOnly:(BOOL)loopbackOnly connectionClass:(Class)classs;
// errno of the last bind that failed, or 0.
+ (int)lastBindErrno;

@end
