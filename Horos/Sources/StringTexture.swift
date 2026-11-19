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
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import AppKit

/** \brief  Converts NSStrings to OpenGL textures

 The implementation of StringTexture, declared in StringTexture.h: the class
 the plugin SDK of Horos and OsiriX drew a string with in an OpenGL view, with
 a texture for each OpenGL context that drew it.

 There is no OpenGL context in the application, and the SDK's class made no
 texture and drew nothing when none was current: that is what this one always
 does. The string, the colours, the margins and the frame (the string's size
 plus the margins) are kept as the SDK's class had them. As in the SDK, an
 object is used from one thread.
 */
@objc @implementation extension StringTexture {
    private static let noOpenGL = "the application draws with Metal and has no OpenGL context to make a texture in or to draw into"

    private final var string: NSAttributedString?
    private final var givenTextColor: NSColor?
    private final var givenBoxColor: NSColor?
    private final var givenBorderColor: NSColor?
    // What -init leaves, as the SDK's did; the other initializers set them.
    private final var margins = NSSize.zero
    private final var frame = NSSize.zero

    // MARK: Initializers

    /// NSObject's, which the SDK's class left as it was: no string, no colour
    /// and no margin.
    override init() {
        super.init()
    }

    init!(attributedString: NSAttributedString!, withTextColor textColor: NSColor!, withBoxColor boxColor: NSColor!,
          withBorderColor borderColor: NSColor!) {
        super.init()
        setUp(attributedString, text: textColor, box: boxColor, border: borderColor)
    }

    init!(string aString: String!, withAttributes attribs: [AnyHashable: Any]!, withTextColor textColor: NSColor!,
          withBoxColor boxColor: NSColor!, withBorderColor borderColor: NSColor!) {
        super.init()
        setUp(Self.attributed(aString, attribs), text: textColor, box: boxColor, border: borderColor)
    }

    // The two that pick up defaults: white text, no box and no border.
    init!(string aString: String!, withAttributes attribs: [AnyHashable: Any]!) {
        super.init()
        let clearBlack = NSColor(deviceRed: 0, green: 0, blue: 0, alpha: 0)
        setUp(Self.attributed(aString, attribs), text: Self.white(alpha: 1), box: clearBlack, border: clearBlack)
    }

    init!(attributedString: NSAttributedString!) {
        super.init()
        setUp(attributedString ?? NSAttributedString(string: ""), text: Self.white(alpha: 1), box: Self.white(alpha: 0),
              border: Self.white(alpha: 0))
    }

    private static func white(alpha: CGFloat) -> NSColor { NSColor(deviceRed: 1, green: 1, blue: 1, alpha: alpha) }

    private static func attributed(_ string: String?, _ attributes: [AnyHashable: Any]?) -> NSAttributedString {
        var typed: [NSAttributedString.Key: Any] = [:]
        for (key, value) in attributes ?? [:] {
            if let name = key as? String { typed[NSAttributedString.Key(name)] = value }
        }
        return NSAttributedString(string: string ?? "", attributes: typed)
    }

    private final func setUp(_ attributedString: NSAttributedString?, text: NSColor?, box: NSColor?, border: NSColor?) {
        string = attributedString?.copy() as? NSAttributedString
        givenTextColor = text
        givenBoxColor = box
        givenBorderColor = border
        margins = NSSize(width: 4, height: 2)
    }

    // MARK: The textures there are not

    func deleteTexture() {
        FormerSDKFacade.inert("StringTexture", "-deleteTexture", because: Self.noOpenGL)
    }

    func deleteTexture(_ c: Any!) {
        FormerSDKFacade.inert("StringTexture", "-deleteTexture:", because: Self.noOpenGL)
    }

    func genTexture() -> UInt32 {
        FormerSDKFacade.inert("StringTexture", "-genTexture", because: Self.noOpenGL)
        return 0
    }

    @objc(genTextureWithBackingScaleFactor:)
    func genTexture(withBackingScaleFactor backingScaleFactor: Float) -> UInt32 {
        FormerSDKFacade.inert("StringTexture", "-genTextureWithBackingScaleFactor:", because: Self.noOpenGL)
        return 0
    }

    func texSize() -> NSSize { .zero }

    // MARK: Accessors

    func textColor() -> NSColor! { givenTextColor }

    func boxColor() -> NSColor! { givenBoxColor }

    func borderColor() -> NSColor! { givenBorderColor }

    /// The string's size plus the margins on each side, found when first
    /// asked for and again after the string changes.
    func frameSize() -> NSSize {
        if frame.width == 0 && frame.height == 0 {
            let size = string?.size() ?? .zero
            frame = NSSize(width: size.width + margins.width * 2, height: size.height + margins.height * 2)
        }
        return frame
    }

    func marginSize() -> NSSize { margins }

    /// NO: the frame always follows the string.
    func staticFrame() -> Bool { false }

    func setString(_ attributedString: NSAttributedString!) {
        string = attributedString?.copy() as? NSAttributedString
        frame = .zero
    }

    func setString(_ aString: String!, withAttributes attribs: [AnyHashable: Any]!) {
        setString(Self.attributed(aString, attribs))
    }

    func setTextColor(_ color: NSColor!) { givenTextColor = color }

    func setBoxColor(_ color: NSColor!) { givenBoxColor = color }

    func setBorderColor(_ color: NSColor!) { givenBorderColor = color }

    // The two settings of the drawing that is not made.

    func setAntiAliasing(_ a: Bool) {
        FormerSDKFacade.inert("StringTexture", "-setAntiAliasing:", because: Self.noOpenGL)
    }

    @objc(setFlippedX:Y:)
    func setFlippedX(_ x: Bool, y: Bool) {
        FormerSDKFacade.inert("StringTexture", "-setFlippedX:Y:", because: Self.noOpenGL)
    }

    // MARK: Drawing

    @objc(drawWithBounds:)
    func draw(withBounds bounds: NSRect) {
        FormerSDKFacade.inert("StringTexture", "-drawWithBounds:", because: Self.noOpenGL)
    }

    @objc(drawAtPoint:ratio:)
    func draw(at point: NSPoint, ratio: Float) {
        FormerSDKFacade.inert("StringTexture", "-drawAtPoint:ratio:", because: Self.noOpenGL)
    }

    @objc(drawAtPoint:)
    func draw(at point: NSPoint) {
        FormerSDKFacade.inert("StringTexture", "-drawAtPoint:", because: Self.noOpenGL)
    }
}
