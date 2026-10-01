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

import AppKit

/// NSCell copies with NSCopyObject: the copy's object references are this
/// cell's pointers, copied bit for bit and never retained. Retain a shared one
/// once for the copy, so that assigning the copy's property afterwards
/// releases what the copy now owns. The former code overwrote the ivars
/// without releasing them, for the same reason.
fileprivate func retainShared(_ copied: AnyObject?, _ original: AnyObject?) {
    if let shared = copied, shared === original {
        _ = Unmanaged.passUnretained(shared).retain()
    }
}

/// [[[self.attributedTitle attributesAtIndex:0 effectiveRange:NULL] mutableCopy] autorelease]
@MainActor fileprivate func titleAttributes(_ cell: NSButtonCell) -> NSMutableDictionary {
    return (cell.attributedTitle.attributes(at: 0, effectiveRange: nil) as NSDictionary).mutableCopy() as! NSMutableDictionary
}

/// -setObject:forKey: as the Objective-C sent it: a nil object raises
/// NSInvalidArgumentException, as it did.
fileprivate func setAttribute(_ object: Any?, forKey key: NSAttributedString.Key, in dictionary: NSMutableDictionary) {
    dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key.rawValue as NSString)
}

/// -[NSString drawInRect:withAttributes:] with the mutable dictionary.
fileprivate func drawText(_ text: NSString?, in rect: NSRect, withAttributes attributes: NSMutableDictionary) {
    text?.draw(in: rect, withAttributes: attributes as? [NSAttributedString.Key: Any])
}

/// -[NSString sizeWithAttributes:] with the mutable dictionary; zero for nil.
fileprivate func textSize(of text: NSString?, withAttributes attributes: NSMutableDictionary) -> NSSize {
    return text?.size(withAttributes: attributes as? [NSAttributedString.Key: Any]) ?? .zero
}

/// [[BrowserController currentBrowser] fontSize:type]: 0 without a browser.
@MainActor fileprivate func browserFontSize(_ type: String) -> CGFloat {
    return CGFloat(BrowserController.currentBrowser()?.fontSize(type) ?? 0)
}

/// The cell of the comparative studies table of the database window.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/ComparativeCell.h> are those of the former class. The properties
/// were atomic and retained; they are nonatomic now, and only the main thread
/// draws and sets the cell.
@objc(ComparativeCell)
public final class ComparativeCell: NSButtonCell {
    @objc public var rightTextFirstLine: NSString?
    @objc public var rightTextSecondLine: NSString?
    @objc public var leftTextSecondLine: NSString?
    @objc public var leftTextFirstLine: NSString?
    @objc public var textColor: NSColor?

    @objc public convenience init() {
        // [super init]: -[NSButtonCell init] is -initTextCell:@"" followed by
        // the title "Button", and Swift only reaches the designated initializers.
        self.init(textCell: "")
        title = "Button"

        self.imagePosition = .imageLeft
        self.alignment = .left
        self.highlightsBy = []
        self.showsStateBy = []
        self.isBordered = false
        self.lineBreakMode = .byTruncatingMiddle
        self.setButtonType(.momentaryChange)
    }

    public override init(textCell string: String) {
        super.init(textCell: string)
    }

    public override init(imageCell image: NSImage?) {
        super.init(imageCell: image)
    }

    public required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! ComparativeCell
        retainShared(copy.rightTextFirstLine, rightTextFirstLine)
        retainShared(copy.rightTextSecondLine, rightTextSecondLine)
        retainShared(copy.leftTextSecondLine, leftTextSecondLine)
        retainShared(copy.leftTextFirstLine, leftTextFirstLine)
        retainShared(copy.textColor, textColor)
        // As before, the copy gets copies of the strings and of the colour.
        copy.rightTextFirstLine = rightTextFirstLine?.copy(with: zone) as? NSString
        copy.rightTextSecondLine = rightTextSecondLine?.copy(with: zone) as? NSString
        copy.leftTextSecondLine = leftTextSecondLine?.copy(with: zone) as? NSString
        copy.leftTextFirstLine = leftTextFirstLine?.copy(with: zone) as? NSString
        copy.textColor = textColor?.copy(with: zone) as? NSColor
        return copy
    }

    public override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        var frame = frame
        frame.origin.x += 1
        super.drawImage(image, withFrame: frame, in: controlView)
    }

    public override func draw(withFrame frame: NSRect, in controlView: NSView) {
        NSColor(calibratedWhite: 0.666, alpha: 0.333).setStroke()
        NSBezierPath.defaultLineWidth = 1
        NSBezierPath.strokeLine(from: NSMakePoint(frame.origin.x, frame.origin.y + frame.size.height + 1.5),
                                to: NSMakePoint(frame.origin.x + frame.size.width, frame.origin.y + frame.size.height + 1.5))

        super.draw(withFrame: frame, in: controlView)
    }

    public override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var frame = frame
        frame.size.width -= 1

        var initialFrame = frame
        let spacer: CGFloat = 2

        // As before, the coloured title is built and not drawn: the lines below
        // draw with the attributes of -attributedTitle.
        let mutableTitle = title.mutableCopy() as! NSMutableAttributedString
        if let textColor = self.textColor {
            mutableTitle.addAttributes([.foregroundColor: textColor], range: NSMakeRange(0, mutableTitle.length))
        }
        _ = mutableTitle

        if BrowserController.horizontalHistory() {
            let attributes = titleAttributes(self)

            var text = self.leftTextFirstLine
            if (text?.length ?? 0) == 0 {
                let color = attributes.value(forKey: NSAttributedString.Key.foregroundColor.rawValue) as? NSColor
                text = "Unnamed"
                setAttribute(color?.blended(withFraction: 0.4, of: NSColor(calibratedWhite: 0.5, alpha: 1)), forKey: .foregroundColor, in: attributes)
            }

            if (self.leftTextSecondLine?.length ?? 0) != 0 {
                let attributes = titleAttributes(self)
                let leftAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                leftAlignmentParagraphStyle.alignment = .left
                leftAlignmentParagraphStyle.lineBreakMode = .byTruncatingTail
                attributes.setObject(leftAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += 1
                drawText(self.leftTextSecondLine, in: frame, withAttributes: attributes)
                frame.origin.y -= 1
            }

            frame.origin.x += 80

            let leftAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            leftAlignmentParagraphStyle.alignment = .left
            leftAlignmentParagraphStyle.lineBreakMode = .byTruncatingTail
            attributes.setObject(leftAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

            frame.origin.y += 1
            drawText(text, in: frame, withAttributes: attributes)
            frame.origin.y -= 1

            frame.origin.x += 330

            if (self.rightTextSecondLine?.length ?? 0) != 0 {
                let attributes = titleAttributes(self)
                let rightAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                rightAlignmentParagraphStyle.alignment = .left
                attributes.setObject(rightAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += 1
                drawText(self.rightTextSecondLine, in: frame, withAttributes: attributes)
                frame.origin.y -= 1
            }

            frame.origin.x += 110

            if self.rightTextFirstLine != nil {
                let attributes = titleAttributes(self)
                let rightAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                rightAlignmentParagraphStyle.alignment = .left
                attributes.setObject(rightAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += 1
                drawText(self.rightTextFirstLine, in: frame, withAttributes: attributes)
                frame.origin.y -= 1
            }
        } else {
            // First Line

            if self.rightTextFirstLine != nil {
                let attributes = titleAttributes(self)
                let rightAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                rightAlignmentParagraphStyle.alignment = .right
                attributes.setObject(rightAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += 1
                drawText(self.rightTextFirstLine, in: frame, withAttributes: attributes)
                frame.origin.y -= 1

                let w = textSize(of: self.rightTextFirstLine, withAttributes: attributes).width
                frame.size.width -= w + spacer
            }

            if true {
                let attributes = titleAttributes(self)

                var text = self.leftTextFirstLine
                if (text?.length ?? 0) == 0 {
                    let color = attributes.value(forKey: NSAttributedString.Key.foregroundColor.rawValue) as? NSColor
                    text = "Unnamed"
                    setAttribute(color?.blended(withFraction: 0.4, of: NSColor(calibratedWhite: 0.5, alpha: 1)), forKey: .foregroundColor, in: attributes)
                }

                let leftAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                leftAlignmentParagraphStyle.alignment = .left
                leftAlignmentParagraphStyle.lineBreakMode = .byTruncatingTail
                attributes.setObject(leftAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += 1
                drawText(text, in: frame, withAttributes: attributes)
                frame.origin.y -= 1
            }

            // Second Line

            frame = initialFrame

            if (self.rightTextSecondLine?.length ?? 0) != 0 {
                let attributes = titleAttributes(self)
                let rightAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                rightAlignmentParagraphStyle.alignment = .right
                attributes.setObject(rightAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                initialFrame.origin.y += browserFontSize("comparativeLineSpace")
                drawText(self.rightTextSecondLine, in: initialFrame, withAttributes: attributes)
                initialFrame.origin.y -= browserFontSize("comparativeLineSpace")

                let w = textSize(of: self.rightTextSecondLine, withAttributes: attributes).width
                frame.size.width -= w + spacer
            }

            if (self.leftTextSecondLine?.length ?? 0) != 0 {
                let attributes = titleAttributes(self)
                let leftAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
                leftAlignmentParagraphStyle.alignment = .left
                leftAlignmentParagraphStyle.lineBreakMode = .byTruncatingTail
                attributes.setObject(leftAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

                frame.origin.y += browserFontSize("comparativeLineSpace")
                drawText(self.leftTextSecondLine, in: frame, withAttributes: attributes)
                frame.origin.y -= browserFontSize("comparativeLineSpace")
            }
        }

        return initialFrame
    }

    public override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView, untilMouseUp: Bool) -> Bool {
        return false
    }

    /// A dummy function... AppKit calls this, and if we don't implement it, it fails.
    @objc(setPlaceholderString:)
    public func setPlaceholderString(_ str: NSString?) {
    }
}
