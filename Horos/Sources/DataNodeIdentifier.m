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


#import "DataNodeIdentifier.h"
#import "PrettyCell.h"
#import "RemoteDicomDatabase.h"
#import "NSImage+N2.h"
#import "NSHost+N2.h"
#import <stdlib.h>
#import "N2Debug.h"

// RemoteDataNodeIdentifier, RemoteDatabaseNodeIdentifier and DicomNodeIdentifier
// are implemented in Swift since #721 (RemoteDataNodeIdentifier.swift). The two
// classes here stay in Objective-C: BrowserController+Sources.m subclasses
// LocalDatabaseNodeIdentifier.

@implementation DataNodeIdentifier

@synthesize location = _location;
@synthesize port = _port;
@synthesize description = _description;
@synthesize dictionary = _dictionary;
@synthesize detected = _detected;
@synthesize entered = _entered;
@synthesize aetitle = _aetitle;

-(id)initWithLocation:(NSString*)location port:(NSUInteger) port aetitle:(NSString*) aetitle description:(NSString*)description dictionary:(NSDictionary*)dictionary {
    if ((self = [self init])) {
        self.location = location;
        self.port = port;
        self.aetitle = aetitle;
        self.description = description;
        self.dictionary = dictionary;
    }
    
    return self;
}

-(void)dealloc {
	self.location = nil;
    self.aetitle = nil;
	self.description = nil;
	self.dictionary = nil;
	[super dealloc];
}

-(BOOL)isEqual:(id)object {
    if ([object isKindOfClass:[DataNodeIdentifier class]])
        return [self isEqualToDataNodeIdentifier:object];
    return NO;
}

// Coherent with -isEqual:, which joins nodes by the dictionary they share or
// their location and, in the subclasses, by a canonical path or through DNS:
// no hash of what a node holds follows all of it, so these nodes share one.
// Sets and dictionaries of nodes stay correct, only linear. DicomNodeIdentifier
// answers the hash of the endpoint it compares (#811).
-(NSUInteger)hash {
    return [DataNodeIdentifier hash];
}

-(BOOL)isEqualToDataNodeIdentifier:(DataNodeIdentifier*)dni {
	if (self.dictionary && self.dictionary == dni.dictionary)
		return YES;
	return [self.location isEqualToString:dni.location];
}

-(BOOL)isEqualToDictionary:(NSDictionary*)d {
    return [self.dictionary isEqual:d];
}

+(CGFloat)sortValueForDataNodeIdentifier:(DataNodeIdentifier*)dni {
    if ([dni isKindOfClass:[LocalDatabaseNodeIdentifier class]])
        return 10;
    if ([dni isKindOfClass:[RemoteDatabaseNodeIdentifier class]])
        return 20;
    if ([dni isKindOfClass:[DicomNodeIdentifier class]])
        return 30;
    return 100;
}

-(CGFloat)sortValue {
    return [[self class] sortValueForDataNodeIdentifier:self];
}

-(NSComparisonResult)compare:(DataNodeIdentifier*)dni {
	NSInteger selfSortValue = [self sortValue], dniSortValue = [dni sortValue];
    if (selfSortValue != dniSortValue)
        return selfSortValue < dniSortValue ? NSOrderedAscending : NSOrderedDescending;
    return [self.description caseInsensitiveCompare:dni.description];
}

-(DicomDatabase*)database { // for subclassers
	return nil;
}

-(NSString*)toolTip {
    NSString *tip = self.location;
    
    if( self.port > 0)
        tip = [tip stringByAppendingFormat: @" - %d", (int) self.port];
    
    if( self.aetitle.length)
        tip = [tip stringByAppendingFormat: @" - %@", self.aetitle];
    
	return tip;
}

-(BOOL)isReadOnly {
	return NO;
}

-(BOOL)available {
    return self.detected;
}

+(NSSet*)keyPathsForValuesAffectingAvailable {
    return [NSSet setWithObject:@"detected"];
}

+(NSSet*)keyPathsForValuesAffectingDescription {
    return [NSSet setWithObject:@"available"]; // this causes 
}

-(void)willDisplayCell:(PrettyCell*)cell {    
    // Do not gray out nodes without a reliable reachability check.
    
    if( [_dictionary valueForKey: @"icon"] && [NSImage imageNamed:[_dictionary valueForKey:@"icon"]])
        cell.image = [NSImage imageNamed:[_dictionary valueForKey:@"icon"]];
}

@end

@implementation LocalDatabaseNodeIdentifier

+(id)localDatabaseNodeIdentifierWithPath:(NSString*)path {
    return [[self class] localDatabaseNodeIdentifierWithPath:path description:nil dictionary:nil];
}

+(id)localDatabaseNodeIdentifierWithPath:(NSString*)path description:(NSString*)description dictionary:(NSDictionary*)dictionary {
    return [[[[self class] alloc] initWithLocation:path port:0 aetitle:@"" description:description dictionary:dictionary] autorelease];
}

-(BOOL)isEqualToDataNodeIdentifier:(DataNodeIdentifier*)dni {
    if (![dni isKindOfClass:[LocalDatabaseNodeIdentifier class]])
        return NO;
    // Databases resolve their paths on open (e.g. /var -> /private/var).
    // Compare the same canonical form so mounted caches keep their source identity.
    NSString *left = [[[DicomDatabase baseDirPathForPath:self.location] stringByResolvingSymlinksInPath] precomposedStringWithCanonicalMapping];
    NSString *right = [[[DicomDatabase baseDirPathForPath:dni.location] stringByResolvingSymlinksInPath] precomposedStringWithCanonicalMapping];
    if (left && right && [left isEqualToString:right])
        return YES;
    return [super isEqualToDataNodeIdentifier:dni];
}

-(BOOL)available {
    return [[NSFileManager defaultManager] fileExistsAtPath:self.location];
}

-(void)willDisplayCell:(PrettyCell*)cell {    
    [super willDisplayCell:cell];

    BOOL isDir;
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.location isDirectory:&isDir]) {
        cell.image = [NSImage imageNamed:@"away.tif"];
        return;
    }
    
    if (!isDir) {
        cell.image = [NSImage imageNamed:@"FileIcon.tif"];
        return;
    }
    
    if( [_dictionary valueForKey: @"icon"] && [NSImage imageNamed:[_dictionary valueForKey:@"icon"]])
    {
        cell.image = [NSImage imageNamed:[_dictionary valueForKey:@"icon"]];
        return;
    }
    
    
    NSImage* im = [[NSWorkspace sharedWorkspace] iconForFile:self.location];
    im.size = [im sizeByScalingProportionallyToSize:NSMakeSize(16,16)];
    cell.image = im;
}

@end

// Declared for Swift in DataNodeIdentifier.h: RemoteDataNodeIdentifier logged a
// nil location with N2LogStackTrace, a C variadic function Swift cannot call.
extern void DataNodeIdentifierLogStackTrace(NSString* message);

void DataNodeIdentifierLogStackTrace(NSString* message)
{
    N2LogStackTrace(@"%@", message);
}

// Declared for Swift in DataNodeIdentifier.h: the factories of the Swift
// subclasses create their nodes here, with the dictionary they were given.
extern id DataNodeIdentifierCreate(Class cls, NSString* location, NSUInteger port, NSString* aetitle, NSString* description, id dictionary);

id DataNodeIdentifierCreate(Class cls, NSString* location, NSUInteger port, NSString* aetitle, NSString* description, id dictionary)
{
    return [[[cls alloc] initWithLocation:location port:port aetitle:aetitle description:description dictionary:dictionary] autorelease];
}
