/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork
//
// File:		GLString.m
//				(Originally StringTexture.m)
//
// Abstract:	Uses Quartz to draw a string into an OpenGL texture
//
// Version:		1.1 - Antialiasing option, Rounded Corners to the frame
//					  self contained OpenGL state, performance enhancements,
//					  other bug fixes.
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

import AppKit

/// The implementation of GLString, declared in GLString.h: the class the
/// plugin SDK of Horos and OsiriX drew a string with in an OpenGL view, as a
/// texture made from a bitmap of the string.
///
/// There is no OpenGL context in the application, so no texture is made and
/// nothing is drawn. What does not need one is kept as the SDK's class had
/// it: the string, the colours, the margins, the frame (the string's size in
/// whole points plus the margins) and, once the texture is asked for, the
/// size it would have had. As in the SDK, an object is used from one thread.
@objc @implementation extension GLString {
    private static let noOpenGL = "the application draws with Metal and has no OpenGL context to make a texture in or to draw into"

    private final var string: NSAttributedString?
    private final var givenTextColor: NSColor?
    private final var givenBoxColor: NSColor?
    private final var givenBorderColor: NSColor?
    // What -init leaves, as the SDK's did; the other initializers set the
    // antialiasing, the margins and the pending update.
    private final var antialiased = false
    private final var margins = NSSize.zero
    private final var frame = NSSize.zero
    private final var texture = NSSize.zero
    private final var requiresUpdate = false

    // MARK: Initializers

    /// NSObject's, which the SDK's class left as it was: no string, no colour
    /// and no margin.
    override init() {
        super.init()
    }

    init!(attributedString: NSAttributedString!, withBoxColor boxColor: NSColor!, withBorderColor borderColor: NSColor!) {
        super.init()
        setUp(attributedString, box: boxColor, border: borderColor)
    }

    init!(string aString: String!, withAttributes attribs: [AnyHashable: Any]!, withBoxColor boxColor: NSColor!,
          withBorderColor borderColor: NSColor!) {
        super.init()
        setUp(Self.attributed(aString, attribs), box: boxColor, border: borderColor)
    }

    // The two that pick up defaults: no box and no border.
    init!(string aString: String!, withAttributes attribs: [AnyHashable: Any]!) {
        super.init()
        setUp(Self.attributed(aString, attribs), box: Self.clearWhite, border: Self.clearWhite)
    }

    init!(attributedString: NSAttributedString!) {
        super.init()
        setUp(attributedString ?? NSAttributedString(string: ""), box: Self.clearWhite, border: Self.clearWhite)
    }

    private static var clearWhite: NSColor { NSColor(deviceRed: 1, green: 1, blue: 1, alpha: 0) }

    private static func attributed(_ string: String?, _ attributes: [AnyHashable: Any]?) -> NSAttributedString {
        var typed: [NSAttributedString.Key: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let name = key as? String { typed[NSAttributedString.Key(name)] = value }
        }
        return NSAttributedString(string: string ?? "", attributes: typed)
    }

    private final func setUp(_ attributedString: NSAttributedString?, box: NSColor?, border: NSColor?) {
        string = attributedString
        givenBoxColor = box
        givenBorderColor = border
        antialiased = true
        margins = NSSize(width: 4, height: 2)
        requiresUpdate = true
    }

    // MARK: The texture there is not

    /// Finds the frame and the size the texture would have, the frame's in
    /// whole texels, as the SDK's did before it asked for the context.
    private final func update() {
        let size = frameSize()
        texture = NSSize(width: max(0, size.width.rounded(.towardZero)), height: max(0, size.height.rounded(.towardZero)))
        requiresUpdate = false
    }

    func genTexture() {
        update()
        FormerSDKFacade.inert("GLString", "-genTexture", because: Self.noOpenGL)
    }

    func texName() -> UInt32 { 0 }

    func texSize() -> NSSize { texture }

    // MARK: Accessors

    func setTextColor(_ color: NSColor!) {
        givenTextColor = color
        requiresUpdate = true
    }

    func textColor() -> NSColor! { givenTextColor }

    func setBoxColor(_ color: NSColor!) {
        givenBoxColor = color
        requiresUpdate = true
    }

    func boxColor() -> NSColor! { givenBoxColor }

    func setBorderColor(_ color: NSColor!) {
        givenBorderColor = color
        requiresUpdate = true
    }

    func borderColor() -> NSColor! { givenBorderColor }

    func marginSize() -> NSSize { margins }

    func antialias() -> Bool { antialiased }

    func setAntialias(_ request: Bool) {
        antialiased = request
        requiresUpdate = true
    }

    /// The string's size in whole points plus the margins on each side, found
    /// when first asked for and again after the string changes.
    func frameSize() -> NSSize {
        if frame.width == 0 && frame.height == 0 {
            let size = string?.size() ?? .zero
            frame = NSSize(width: size.width.rounded(.towardZero) + margins.width * 2,
                           height: size.height.rounded(.towardZero) + margins.height * 2)
        }
        return frame
    }

    /// NO: the frame always follows the string.
    func staticFrame() -> Bool { false }

    func setString(_ attributedString: NSAttributedString!) {
        string = attributedString
        frame = .zero
        requiresUpdate = true
    }

    func setString(_ aString: String!, withAttributes attribs: [AnyHashable: Any]!) {
        setString(Self.attributed(aString, attribs))
    }

    // MARK: Drawing

    @objc(drawAtPoint:view:)
    func draw(at p: NSPoint, view: NSView!) {
        if requiresUpdate { update() }
        FormerSDKFacade.inert("GLString", "-drawAtPoint:view:", because: Self.noOpenGL)
    }

    @objc(drawWithBounds:)
    func draw(withBounds bounds: NSRect) {
        if requiresUpdate { update() }
        FormerSDKFacade.inert("GLString", "-drawWithBounds:", because: Self.noOpenGL)
    }
}
