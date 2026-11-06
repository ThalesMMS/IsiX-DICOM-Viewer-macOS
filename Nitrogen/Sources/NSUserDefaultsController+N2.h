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


// Implemented in Swift (NSUserDefaultsController+N2.swift). The accessors are
// nonisolated: the preferences of NSUserDefaults (OsiriX) read them on any
// thread.
@interface NSUserDefaultsController (N2)

-(NSString*)stringForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(NSArray*)arrayForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(NSDictionary*)dictionaryForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(NSData*)dataForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(NSInteger)integerForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(float)floatForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(double)doubleForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(BOOL)boolForKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;

-(void)setString:(NSString*)str forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setArray:(NSArray*)arr forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setDictionary:(NSDictionary*)dic forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setData:(NSData*)dat forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setInteger:(NSInteger)i forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setFloat:(float)f forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setDouble:(double)d forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;
-(void)setBool:(BOOL)flag forKey:(NSString*)defaultName NS_SWIFT_NONISOLATED;

@end

CF_EXTERN_C_BEGIN
// we often need to compose the string constants declared earlier in this file with a values key path - these functions/methods make that easier
extern NSString* valuesKeyPath(NSString* key);
CF_EXTERN_C_END
		
// NSObject (N2ValuesBinding), -addObserver:forValuesKey:options:context: and
// -removeObserver:forValuesKey:, is a Swift extension: only Swift observes
// through it.

