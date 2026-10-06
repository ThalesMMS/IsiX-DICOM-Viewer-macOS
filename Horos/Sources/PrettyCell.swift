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

/// The cell of the sources and albums tables of the database window: an image,
/// the title, a right-aligned text and views drawn on the right.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/PrettyCell.h> are those of the former class. The properties were
/// atomic and retained; they are nonatomic now, and only the main thread
/// draws and sets the cell.
@objc(PrettyCell)
public final class PrettyCell: NSButtonCell {
    @objc public var rightText: NSString?
    @objc public private(set) var rightSubviews: NSMutableArray?
    @objc public var textColor: NSColor?

    @objc public convenience init() {
        // [super init]: -[NSButtonCell init] is -initTextCell:@"" followed by
        // the title "Button", and Swift only reaches the designated initializers.
        self.init(textCell: "")
        title = "Button"

        self.rightSubviews = NSMutableArray()
        self.imagePosition = .imageLeft
        self.alignment = .left
        self.imageScaling = .scaleProportionallyUpOrDown
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
        let copy = super.copy(with: zone) as! PrettyCell
        retainShared(copy.rightText, rightText)
        retainShared(copy.textColor, textColor)
        retainShared(copy.rightSubviews, rightSubviews)
        // As before, the copy gets copies of the text and of the colour, and a
        // mutable copy of the array (the same views).
        copy.rightText = rightText?.copy(with: zone) as? NSString
        copy.textColor = textColor?.copy(with: zone) as? NSColor
        copy.rightSubviews = rightSubviews?.mutableCopy(with: zone) as? NSMutableArray
        return copy
    }

    /// [self.rightSubviews objectAtIndex:index]; nil without the array, as a
    /// message to nil answered.
    private func rightSubview(at index: Int) -> NSView? {
        return self.rightSubviews?.object(at: index) as? NSView
    }

    @objc(rectForSubviewAtIndex:withFrame:)
    public func rectForSubview(at index: Int, withFrame frame: NSRect) -> NSRect {
        // An NSInteger, as before: each width is added and truncated.
        var previousSummedupWidth: Int = 0
        var i: Int32 = 0
        while Int(i) < index {
            let subview = self.rightSubview(at: Int(i))
            previousSummedupWidth = Int(CGFloat(previousSummedupWidth) + (subview?.frame.size.width ?? 0))
            i += 1
        }

        let subview = self.rightSubview(at: index)
        let subviewFrame = subview?.frame ?? .zero

        return NSRect(origin: NSMakePoint(frame.origin.x + frame.size.width - CGFloat(previousSummedupWidth) - subviewFrame.size.width,
                                          frame.origin.y + (frame.size.height - subviewFrame.size.height) / 2),
                      size: subviewFrame.size)
    }

    @objc(rectForSubview:withFrame:)
    public func rect(forSubview subview: NSView?, withFrame frame: NSRect) -> NSRect {
        return self.rectForSubview(at: self.rightSubviews?.index(of: subview as Any) ?? 0, withFrame: frame)
    }

    public override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        var frame = frame
        frame.origin.x += 1
        super.drawImage(image, withFrame: frame, in: controlView)
    }

    public override func draw(withFrame frame: NSRect, in controlView: NSView) {
        var frame = frame
        let initialFrame = frame

        for case let subview as NSView in self.rightSubviews ?? NSMutableArray() {
            let subviewFrame = self.rect(forSubview: subview, withFrame: initialFrame)
            subview.frame = subviewFrame
            if subview.superview == nil {
                controlView.addSubview(subview)
            }
            if subviewFrame.origin.x < frame.origin.x + frame.size.width {
                frame.size.width = subviewFrame.origin.x - frame.origin.x
            }
        }

        super.draw(withFrame: frame, in: controlView)
    }

    public override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        var frame = frame
        let initialFrame = frame
        let spacer: CGFloat = 2

        let mutableTitle = title.mutableCopy() as! NSMutableAttributedString
        if let textColor = self.textColor {
            mutableTitle.addAttributes([.foregroundColor: textColor], range: NSMakeRange(0, mutableTitle.length))
        }
        let title: NSAttributedString = mutableTitle

        if let rightText = self.rightText, rightText.length != 0 && rightText.length < 100 {
            let attributes = (self.attributedTitle.attributes(at: 0, effectiveRange: nil) as NSDictionary).mutableCopy() as! NSMutableDictionary
            let rightAlignmentParagraphStyle = NSParagraphStyle.default.mutableCopy() as! NSMutableParagraphStyle
            rightAlignmentParagraphStyle.alignment = .right
            attributes.setObject(rightAlignmentParagraphStyle, forKey: NSAttributedString.Key.paragraphStyle.rawValue as NSString)

            frame.origin.y += 2
            rightText.draw(in: frame, withAttributes: attributes as? [NSAttributedString.Key: Any])
            frame.origin.y -= 2

            let w = rightText.size(withAttributes: attributes as? [NSAttributedString.Key: Any]).width
            frame.size.width -= w + spacer
        }

        frame.origin.x += spacer
        frame.size.width -= spacer

        _ = super.drawTitle(title, withFrame: frame, in: controlView)

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
