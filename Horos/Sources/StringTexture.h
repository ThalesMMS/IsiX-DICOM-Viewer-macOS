/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Êversion 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. ÊSee the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. ÊIf not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Ê OsiriX
 ÊCopyright (c) OsiriX Team
 ÊAll rights reserved.
 ÊDistributed under GNU - LGPL
 Ê
 ÊSee http://www.osirix-viewer.com/copyright.html for details.
 Ê Ê This software is distributed WITHOUT ANY WARRANTY; without even
 Ê Ê the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Ê Ê PURPOSE.
 ============================================================================*/


#import <Cocoa/Cocoa.h>


/** \brief  Converts NSStrings to OpenGL textures

The class the plugin SDK of Horos and OsiriX drew a string with in an OpenGL
view, with one texture for each OpenGL context that drew it. The application
has no OpenGL context: the class keeps the string and the colours and answers
the size of the frame, which comes from the string alone, and it makes no
texture and draws nothing, as the SDK's did when no context was current.
-genTexture answers 0 and -texSize a zero size.

The SDK declared the texture names as GLuint, which is unsigned int, and the
context of -deleteTexture: as NSOpenGLContext *, which is an object here.

StringTexture.swift implements the class (@objc @implementation).
*/
@interface StringTexture : NSObject

// designated initializer
- (id) initWithAttributedString:(NSAttributedString *)attributedString withTextColor:(NSColor *)textColor withBoxColor:(NSColor *)boxColor withBorderColor:(NSColor *)borderColor NS_SWIFT_NAME(init(attributedString:withTextColor:withBoxColor:withBorderColor:));

- (id) initWithString:(NSString *)aString withAttributes:(NSDictionary *)attribs withTextColor:(NSColor *)textColor withBoxColor:(NSColor *)boxColor withBorderColor:(NSColor *)borderColor NS_SWIFT_NAME(init(string:withAttributes:withTextColor:withBoxColor:withBorderColor:));

// basic methods that pick up defaults
- (id) initWithString:(NSString *)aString withAttributes:(NSDictionary *)attribs;
- (id) initWithAttributedString:(NSAttributedString *)attributedString;

- (void) deleteTexture NS_SWIFT_NAME(deleteTexture()); // no texture was made: nothing to delete
- (void) deleteTexture:(id) c NS_SWIFT_NAME(deleteTexture(_:)); // the same

- (NSSize) texSize; // (0, 0): no texture is allocated

- (void) setFlippedX: (BOOL) x Y:(BOOL) y NS_SWIFT_NAME(setFlippedX(_:y:));
- (NSColor *) textColor; // get the pre-multiplied default text color (includes alpha) string attributes could override this
- (NSColor *) boxColor; // get the pre-multiplied box color (includes alpha) alpha of 0.0 means no background box
- (NSColor *) borderColor; // get the pre-multiplied border color (includes alpha) alpha of 0.0 means no border
- (BOOL) staticFrame; // returns whether or not a static frame will be used

- (NSSize) frameSize; // returns either dynamc frame (text size + margins) or static frame size (switch with staticFrame)

- (NSSize) marginSize; // current margins for text offset and pads for dynamic frame

- (unsigned int) genTexture; // 0: makes no texture
- (unsigned int) genTextureWithBackingScaleFactor: (float) backingScaleFactor; // the same
- (void) drawWithBounds:(NSRect)bounds; // draws nothing
- (void) drawAtPoint:(NSPoint)point NS_SWIFT_NAME(draw(at:)); // the same
- (void) drawAtPoint:(NSPoint)point ratio:(float) ratio NS_SWIFT_NAME(draw(at:ratio:)); // the same

- (void) setString:(NSAttributedString *)attributedString; // set string after initial creation
- (void) setString:(NSString *)aString withAttributes:(NSDictionary *)attribs; // set string after initial creation

- (void) setTextColor:(NSColor *)color; // set default text color
- (void) setBoxColor:(NSColor *)color NS_SWIFT_NAME(setBoxColor(_:)); // set default text color
- (void) setBorderColor:(NSColor *)color; // set default text color
- (void) setAntiAliasing:(BOOL) a;
@end
