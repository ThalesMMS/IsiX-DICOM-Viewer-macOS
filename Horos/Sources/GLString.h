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
//
// File:		GLString.h 
//				(Originally StringTexture.h)
//
// Abstract:	Uses Quartz to draw a string into an OpenGL texture
//
// Version:		1.1 - Minor enhancements and bug fixes.
//				1.0 - Original release.
//				
//
// Disclaimer:	IMPORTANT:  This Apple software is supplied to you by Apple Inc. ("Apple")
//				in consideration of your agreement to the following terms, and your use,
//				installation, modification or redistribution of this Apple software
//				constitutes acceptance of these terms.  If you do not agree with these
//				terms, please do not use, install, modify or redistribute this Apple
//				software.
//
//				In consideration of your agreement to abide by the following terms, and
//				subject to these terms, Apple grants you a personal, non - exclusive
//				license, under Apple's copyrights in this original Apple software ( the
//				"Apple Software" ), to use, reproduce, modify and redistribute the Apple
//				Software, with or without modifications, in source and / or binary forms;
//				provided that if you redistribute the Apple Software in its entirety and
//				without modifications, you must retain this notice and the following text
//				and disclaimers in all such redistributions of the Apple Software. Neither
//				the name, trademarks, service marks or logos of Apple Inc. may be used to
//				endorse or promote products derived from the Apple Software without specific
//				prior written permission from Apple.  Except as expressly stated in this
//				notice, no other rights or licenses, express or implied, are granted by
//				Apple herein, including but not limited to any patent rights that may be
//				infringed by your derivative works or by other works in which the Apple
//				Software may be incorporated.
//
//				The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO
//				WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED
//				WARRANTIES OF NON - INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A
//				PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION
//				ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
//
//				IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR
//				CONSEQUENTIAL DAMAGES ( INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//				SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//				INTERRUPTION ) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, MODIFICATION
//				AND / OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER
//				UNDER THEORY OF CONTRACT, TORT ( INCLUDING NEGLIGENCE ), STRICT LIABILITY OR
//				OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright ( C ) 2003-2007 Apple Inc. All Rights Reserved.
//

#import <Cocoa/Cocoa.h>

// The class the plugin SDK of Horos and OsiriX drew a string with in an OpenGL
// view: it drew the string into a bitmap with Quartz, made a texture of it in
// the current OpenGL context and drew the texture. The application has no
// OpenGL context: the class keeps the string and the colours and answers the
// sizes, which come from the string alone, and it makes no texture and draws
// nothing. -texName is always 0.
//
// The SDK declared -texName as GLuint, which is unsigned int.
//
// GLString.swift implements the class (@objc @implementation).
@interface GLString : NSObject

// designated initializer
- (id) initWithAttributedString:(NSAttributedString *)attributedString withBoxColor:(NSColor *)boxColor withBorderColor:(NSColor *)borderColor NS_SWIFT_NAME(init(attributedString:withBoxColor:withBorderColor:));

- (id) initWithString:(NSString *)aString withAttributes:(NSDictionary *)attribs withBoxColor:(NSColor *)boxColor withBorderColor:(NSColor *)borderColor NS_SWIFT_NAME(init(string:withAttributes:withBoxColor:withBorderColor:));

// basic methods that pick up defaults
- (id) initWithString:(NSString *)aString withAttributes:(NSDictionary *)attribs;
- (id) initWithAttributedString:(NSAttributedString *)attributedString;

- (unsigned int) texName; // 0: no texture is allocated
- (NSSize) texSize; // the size in texels of the texture -genTexture would have made, (0, 0) before it is asked for

- (NSColor *) textColor; // get the pre-multiplied default text color (includes alpha) string attributes could override this
- (NSColor *) boxColor; // get the pre-multiplied box color (includes alpha) alpha of 0.0 means no background box
- (NSColor *) borderColor; // get the pre-multiplied border color (includes alpha) alpha of 0.0 means no border
- (BOOL) staticFrame; // returns whether or not a static frame will be used

- (NSSize) frameSize; // returns either dynamc frame (text size + margins) or static frame size (switch with staticFrame)

- (NSSize) marginSize; // current margins for text offset and pads for dynamic frame

- (void) genTexture; // finds the sizes; makes no texture
- (void) drawWithBounds:(NSRect)bounds; // finds the sizes if a setting changed; draws nothing
- (void) drawAtPoint: (NSPoint) p view:(NSView*) view; // the same

- (void) setString:(NSAttributedString *)attributedString; // set string after initial creation
- (void) setString:(NSString *)aString withAttributes:(NSDictionary *)attribs; // set string after initial creation

- (void) setTextColor:(NSColor *)color; // set default text color
- (void) setBoxColor:(NSColor *)color NS_SWIFT_NAME(setBoxColor(_:)); // set default text color
- (void) setBorderColor:(NSColor *)color; // set default text color

- (BOOL) antialias;
- (void) setAntialias:(bool)request;

@end
