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


// RemoteDataNodeIdentifier, RemoteDatabaseNodeIdentifier and
// DicomNodeIdentifier are implemented in Swift
// (Horos/Sources/RemoteDataNodeIdentifier.swift). DataNodeIdentifier and
// LocalDatabaseNodeIdentifier stay in Objective-C: BrowserController+Sources.m
// subclasses LocalDatabaseNodeIdentifier. This header keeps
// <Horos/DataNodeIdentifier.h>: it declares the two Objective-C classes, then
// brings in the generated interface, which declares the Swift ones with the
// same class names and selectors.

#import <Cocoa/Cocoa.h>


@class DicomDatabase, PrettyCell;



@interface DataNodeIdentifier : NSObject {
	NSString* _location;
    NSString* _aetitle;
    NSUInteger _port;
	NSString* _description;
	NSDictionary* _dictionary;
    BOOL _detected; // i.e. if this node was detected through bonjour, or mounted
    BOOL _entered; // if this node is listed in the user defaults, entered by the user
}

@property(retain) NSString* location;
@property(retain) NSString* aetitle;
@property NSUInteger port;
@property(retain) NSString* description;
@property(retain) NSDictionary* dictionary;
@property BOOL detected;
@property BOOL entered;

// Not seen by Swift: a Swift subclass that inherited it would answer it through
// a thunk that copies the dictionary into a Swift one, and the node would no
// longer hold the dictionary it was given (-isEqualToDataNodeIdentifier:
// compares dictionaries by identity). The Swift subclasses create nodes with
// DataNodeIdentifierCreate().
-(id)initWithLocation:(NSString*)location port:(NSUInteger) port aetitle:(NSString*) aetitle description:(NSString*)description dictionary:(NSDictionary*)dictionary NS_SWIFT_UNAVAILABLE("use DataNodeIdentifierCreate()");

-(BOOL)isEqualToDataNodeIdentifier:(DataNodeIdentifier*)dni;
-(BOOL)isEqualToDictionary:(NSDictionary*)d;
-(NSComparisonResult)compare:(DataNodeIdentifier*)other;

-(DicomDatabase*)database;

-(BOOL)isReadOnly;
-(NSString*)toolTip;

-(void)willDisplayCell:(PrettyCell*)cell;

@end

@interface LocalDatabaseNodeIdentifier : DataNodeIdentifier

+(id)localDatabaseNodeIdentifierWithPath:(NSString*)path;
+(id)localDatabaseNodeIdentifierWithPath:(NSString*)path description:(NSString*)description dictionary:(NSDictionary*)dictionary;
    
@end

// Imported after the two classes above: the generated interface declares the
// Swift ones as their subclasses.
#ifdef HOROS_BRIDGING_HEADER
// Swift is compiling the classes themselves: headers it imports may only name them.
@class RemoteDataNodeIdentifier, RemoteDatabaseNodeIdentifier, DicomNodeIdentifier;

// N2LogStackTrace(@"%@", message), in DataNodeIdentifier.m: Swift cannot call
// the variadic function.
extern void DataNodeIdentifierLogStackTrace(NSString* message);

// [[[cls alloc] initWithLocation:port:aetitle:description:dictionary:] autorelease],
// in DataNodeIdentifier.m, for the factories of the Swift subclasses. The
// dictionary is typed id so that Swift hands the object itself over.
extern id DataNodeIdentifierCreate(Class cls, NSString* location, NSUInteger port, NSString* aetitle, NSString* description, id dictionary);
#else
@class RemoteDataNodeIdentifier, RemoteDatabaseNodeIdentifier, DicomNodeIdentifier;
#import "Horos-Swift.h"
#endif
