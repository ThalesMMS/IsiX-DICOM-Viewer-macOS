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
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Cocoa

/// FRAME_MARGIN of the former file.
private let frameMargin: Float = 10

/// The custom annotations layout: an image-sized area with eight
/// CIAPlaceHolder drop areas. It is the xib's custom view, made by
/// -initWithFrame:.
///
/// Implemented in Swift since #711: the Objective-C name, the selectors and
/// CIALayoutView.h are those of the former class.
@objc(CIALayoutView)
public final class CIALayoutView: NSControl {
    private var placeHolders: [CIAPlaceHolder]?
    private var disabledText: String?
    private var enabledText: String?

    public override init(frame: NSRect) {
        super.init(frame: frame)

        setDefaultDisabledText()
        setDefaultEnabledText()

        // The layout view contains 8 place holders for Annotations. They are labeled as follow:
        //  +-------+
        //	| 5 6 7 |
        //	| 3   4 |
        //	| 0 1 2 |
        //	+-------+

        // Frames Origins (x, y) of the place holders in the layout view, in
        // `float` as before
        let defaultSize = CIAPlaceHolder.defaultSize()
        var x = [Float](repeating: 0, count: 8), y = [Float](repeating: 0, count: 8)
        x[0] = 0.0 + frameMargin
        x[3] = x[0]; x[5] = x[0]
        x[1] = Float(frame.size.width / 2.0 - defaultSize.width / 2.0)
        x[6] = x[1]
        x[2] = Float(frame.size.width - defaultSize.width - CGFloat(frameMargin))
        x[4] = x[2]; x[7] = x[2]

        y[0] = 0.0 + frameMargin
        y[1] = y[0]; y[2] = y[0]
        y[3] = Float(frame.size.height / 2.0 - defaultSize.height / 2.0)
        y[4] = y[3]
        y[5] = Float(frame.size.height - defaultSize.height - CGFloat(frameMargin))
        y[6] = y[5]; y[7] = y[5]

        var align = [CIAPlaceHolderAlignement](repeating: CIAPlaceHolderAlignLeft, count: 8)
        align[0] = CIAPlaceHolderAlignLeft
        align[3] = CIAPlaceHolderAlignLeft
        align[5] = CIAPlaceHolderAlignLeft
        align[1] = CIAPlaceHolderAlignCenter
        align[6] = CIAPlaceHolderAlignCenter
        align[2] = CIAPlaceHolderAlignRight
        align[4] = CIAPlaceHolderAlignRight
        align[7] = CIAPlaceHolderAlignRight

        var placeHolderMutableArray: [CIAPlaceHolder] = []
        placeHolderMutableArray.reserveCapacity(8)
        for i in 0..<8 {
            let aPlaceHolder = CIAPlaceHolder(frame: NSMakeRect(CGFloat(x[i]), CGFloat(y[i]),
                                                                CIAPlaceHolder.defaultSize().width,
                                                                CIAPlaceHolder.defaultSize().height))
            aPlaceHolder.setAlignment(align[i])
            if i == 1 { aPlaceHolder.setOrientationWidgetPosition(CIAPlaceHolderOrientationWidgetBottom) }
            addSubview(aPlaceHolder)
            placeHolderMutableArray.append(aPlaceHolder)
        }
        placeHolders = placeHolderMutableArray
    }

    /// The former class had no -initWithCoder: of its own: NSControl's left it
    /// without place holders or texts. The xib makes it with -initWithFrame:.
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc public func updatePlaceHolderOrigins() {
        updatePlaceHolderOrigins(in: bounds)
    }

    @objc(updatePlaceHolderOriginsInRect:)
    public func updatePlaceHolderOrigins(in rect: NSRect) {
        guard let placeHolderArray = placeHolders, placeHolderArray.count >= 8 else { return }
        // The layout view contains 8 place holders for Annotations. They are labeled as follow:
        //  +-------+
        //	| 5 6 7 |
        //	| 3   4 |
        //	| 0 1 2 |
        //	+-------+

        // Frames Origins (x, y) of the place holders in the layout view, in `float`
        func width(_ i: Int) -> CGFloat { placeHolderArray[i].frame.size.width }
        func height(_ i: Int) -> CGFloat { placeHolderArray[i].frame.size.height }
        var x = [Float](repeating: 0, count: 8), y = [Float](repeating: 0, count: 8)
        x[0] = 0.0 + frameMargin
        x[3] = x[0]; x[5] = x[0]
        x[1] = Float(rect.size.width / 2.0 - width(1) / 2.0)
        x[6] = Float(rect.size.width / 2.0 - width(6) / 2.0)
        x[2] = Float(rect.size.width - width(2) - CGFloat(frameMargin))
        x[4] = Float(rect.size.width - width(4) - CGFloat(frameMargin))
        x[7] = Float(rect.size.width - width(7) - CGFloat(frameMargin))

        y[0] = 0.0 + frameMargin
        y[1] = y[0]; y[2] = y[0]
        y[3] = Float(rect.size.height / 2.0 - height(3) / 2.0)
        y[4] = Float(rect.size.height / 2.0 - height(4) / 2.0)
        y[5] = Float(rect.size.height - height(5) - CGFloat(frameMargin))
        y[6] = Float(rect.size.height - height(6) - CGFloat(frameMargin))
        y[7] = Float(rect.size.height - height(7) - CGFloat(frameMargin))

        for i in 0..<8 {
            placeHolderArray[i].setFrameOrigin(NSMakePoint(CGFloat(x[i]), CGFloat(y[i])))
            placeHolderArray[i].needsDisplay = true
        }
    }

    public override func draw(_ updateRect: NSRect) {
        let rect = bounds

        updatePlaceHolderOrigins(in: rect)

        let borderFrame = NSBezierPath(rect: rect)

        NSColor.controlBackgroundColor.set()
        borderFrame.fill()

        borderFrame.lineWidth = 2.0
        NSColor.gray.set()
        borderFrame.stroke()

        var attrsDictionary: [NSAttributedString.Key: Any] = [:]
        attrsDictionary[.foregroundColor] = NSColor.gray

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.setParagraphStyle(NSParagraphStyle.default)
        paragraphStyle.alignment = .center
        attrsDictionary[.paragraphStyle] = paragraphStyle

        attrsDictionary[.font] = NSFont.systemFont(ofSize: 20.0)

        let contentText: NSAttributedString
        let textWidth: Float, textHeight: Float
        if isEnabled {
            contentText = ciaAttributedString(enabledText, attributes: attrsDictionary)
            textWidth = Float(contentText.size().width / 2.0)
            textHeight = Float(contentText.size().height * 3.0)
        } else {
            contentText = ciaAttributedString(disabledText, attributes: attrsDictionary)

            textWidth = Float(rect.size.width / 2.0)
            textHeight = Float(contentText.size().height * 3.0)
        }

        let textRect = NSMakeRect(rect.origin.x + rect.size.width / 2.0 - CGFloat(textWidth) / 2.0,
                                  rect.origin.y + rect.size.height / 2.0 - CGFloat(textHeight) / 2.0,
                                  CGFloat(textWidth), CGFloat(textHeight))
        contentText.draw(in: textRect)
    }

    @objc public var placeHolderArray: [CIAPlaceHolder]! {
        return placeHolders
    }

    public override var isEnabled: Bool {
        get { return super.isEnabled }
        set { super.isEnabled = newValue }
    }

    @objc(setDisabledText:)
    public func setDisabledText(_ text: String!) {
        disabledText = text
    }

    @objc public func setDefaultEnabledText() {
        enabledText = NSLocalizedString("Drag Annotations in the place holders", comment: "")
    }

    @objc public func setDefaultDisabledText() {
        disabledText = NSLocalizedString("Same as Default Settings...", comment: "")
    }
}
