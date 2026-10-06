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

// NSString (N2) and NSAttributedString (N2) are implemented in Swift
// (Nitrogen/Sources/NSString+N2.swift). This header keeps <Horos/NSString+N2.h>:
// it brings in the generated interface, whose Swift extensions declare the same
// selectors.

#import <Cocoa/Cocoa.h>

// A C function: it does not migrate. Its definition, with the C++ name the
// application exports, is in NSString+N2+CAPI.mm.
extern NSString* N2NonNullString(NSString* s);

#if defined(HOROS_BRIDGING_HEADER)
// Swift is compiling the extensions itself.
#elif __has_include("Horos-Swift.h")
#import "Horos-Swift.h"
#else
// A target without Swift, the Decompress helper: code that only names these
// selectors compiles there, as it did before, without their implementation.
@interface NSString (N2)

-(NSString *)stringByTruncatingToLength:(NSInteger)theWidth;
+(NSString*)sizeString:(unsigned long long)size;
+(NSString*)timeString:(NSTimeInterval)time;
+(NSString*)timeString:(NSTimeInterval)time maxUnits:(NSInteger)maxUnits;
-(NSString*)stringByTrimmingStartAndEnd;

-(NSString*)xmlEscapedString;

-(NSString*)ASCIIString;

-(BOOL)contains:(NSString*)str;

-(NSString*)stringByPrefixingLinesWithString:(NSString*)prefix;
+(NSString*)stringByRepeatingString:(NSString*)string times:(NSUInteger)times;
-(NSString*)suspendedString;

-(NSRange)range;

//-(NSString*)resolvedPathString;
-(NSString*)stringByComposingPathWithString:(NSString*)rel;

-(NSArray*)componentsWithLength:(NSUInteger)len;

-(BOOL)isEmail;

-(void)splitStringAtCharacterFromSet:(NSCharacterSet*)charset intoChunks:(NSString**)part1 :(NSString**)part2 separator:(unichar*)separator;

// Legacy uppercase MD5 of the UTF-8 C string (through its first NUL).
// SDK compatibility only; not for security or new persistent identities.
-(NSString*)md5;

@end

@interface NSAttributedString (N2)

-(NSRange)range;

@end
#endif
