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

/// Cell that can contain text and and image.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/ImageAndTextCell.h> are those of the former class.
@objc(ImageAndTextCell)
public final class ImageAndTextCell: NSTextFieldCell {
    // The former private ivars.
    private var imageStorage: NSImage?
    private var lastImage: NSImage?
    private var lastImageAlternate: NSImage?
    private var clickedInLastImageStorage = false

    public override func hitTest(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        if let lastImage = self.lastImage {
            let pt = controlView.convert(theEvent.locationInWindow, from: nil)
            var imageFrame = NSZeroRect, cellFrameOut = NSZeroRect

            let imageSize = lastImage.size
            NSDivideRect(cellFrame, &imageFrame, &cellFrameOut, 3 + imageSize.width, .maxX)

            if NSMouseInRect(pt, cellFrameOut, false) == false {
                if clickedInLastImageStorage == false {
                    let im = self.lastImage
                    self.lastImage = lastImageAlternate
                    lastImageAlternate = im
                    clickedInLastImageStorage = true
                    controlView.display()
                }

                BrowserController.currentBrowser()?.alternateButtonPressed(nil)
            } else {
                if clickedInLastImageStorage == true {
                    let im = self.lastImage
                    self.lastImage = lastImageAlternate
                    lastImageAlternate = im
                    clickedInLastImageStorage = false
                    controlView.display()
                }
            }
        }

        return super.hitTest(for: theEvent, in: cellFrame, of: controlView)
    }

    @objc(clickedInLastImage)
    public func clickedInLastImage() -> Bool {
        return clickedInLastImageStorage
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        let cell = super.copy(with: zone) as! ImageAndTextCell
        retainShared(cell.imageStorage, imageStorage)
        retainShared(cell.lastImage, lastImage)
        retainShared(cell.lastImageAlternate, lastImageAlternate)
        // As before, the copy retains the same images.
        cell.imageStorage = imageStorage
        cell.lastImage = lastImage
        cell.lastImageAlternate = lastImageAlternate
        cell.isEditable = self.isEditable
        return cell
    }

    /// The former -image and -setImage:, which override NSCell's.
    public override var image: NSImage? {
        get {
            return imageStorage
        }
        set {
            if newValue !== imageStorage {
                imageStorage = newValue
            }
        }
    }

    @objc(setLastImage:)
    public func setLastImage(_ anImage: NSImage?) {
        if anImage !== lastImage {
            lastImage = anImage
        }
    }

    @objc(setLastImageAlternate:)
    public func setLastImageAlternate(_ anImage: NSImage?) {
        if anImage !== lastImageAlternate {
            lastImageAlternate = anImage
        }
    }

    @objc(imageFrameForCellFrame:)
    public func imageFrame(forCellFrame cellFrame: NSRect) -> NSRect {
        if let image = imageStorage {
            var imageFrame = NSRect.zero
            imageFrame.size = image.size
            imageFrame.origin = cellFrame.origin
            imageFrame.origin.x += 3
            imageFrame.origin.y += ceil((cellFrame.size.height - imageFrame.size.height) / 2)
            return imageFrame
        } else {
            return NSZeroRect
        }
    }

    public override func edit(withFrame aRect: NSRect, in controlView: NSView, editor textObj: NSText, delegate anObject: Any?, event theEvent: NSEvent?) {
        NSLog("Edit ImageAnd TextCell")
        var textFrame = NSZeroRect, imageFrame = NSZeroRect
        NSDivideRect(aRect, &imageFrame, &textFrame, 3 + (imageStorage?.size.width ?? 0), .minX)
        super.edit(withFrame: textFrame, in: controlView, editor: textObj, delegate: anObject, event: theEvent)
    }

    public override func select(withFrame aRect: NSRect, in controlView: NSView, editor textObj: NSText, delegate anObject: Any?, start selStart: Int, length selLength: Int) {
        var textFrame = NSZeroRect, imageFrame = NSZeroRect
        NSDivideRect(aRect, &imageFrame, &textFrame, 3 + (imageStorage?.size.width ?? 0), .minX)
        super.select(withFrame: textFrame, in: controlView, editor: textObj, delegate: anObject, start: selStart, length: selLength)
    }

    public override func draw(withFrame cellFrameIn: NSRect, in controlView: NSView) {
        var cellFrame = cellFrameIn

        // @try: an exception drawing the images is logged, and the text is
        // drawn with the frame as far as it got.
        do {
            try HorosObjCException.perform {
                if let image = self.imageStorage {
                    var imageFrame = NSZeroRect

                    let imageSize = image.size
                    NSDivideRect(cellFrame, &imageFrame, &cellFrame, 3 + imageSize.width, .minX)
                    // A nil backgroundColor leaves whatever colour the context already had
                    // and NSRectFill then paints the image slice with it, which in a fresh
                    // context is black. And NSRectFill overwrites alpha instead of blending,
                    // so a colour with alpha - every semantic one has some - came out solid
                    // (#380, A300).
                    if self.drawsBackground, let backgroundColor = self.backgroundColor {
                        backgroundColor.set()
                        imageFrame.fill(using: .sourceOver)
                    }
                    imageFrame.origin.x += 3
                    imageFrame.size = imageSize

                    imageFrame.origin.y += ceil((cellFrame.size.height - imageFrame.size.height) / 2)

                    image.draw(at: imageFrame.origin, from: NSZeroRect, operation: .sourceOver, fraction: 1.0)
                }

                if let lastImage = self.lastImage {
                    var imageFrame = NSZeroRect

                    let imageSize = lastImage.size
                    NSDivideRect(cellFrame, &imageFrame, &cellFrame, 3 + imageSize.width, .maxX)
                    // A nil backgroundColor leaves whatever colour the context already had
                    // and NSRectFill then paints the image slice with it, which in a fresh
                    // context is black. And NSRectFill overwrites alpha instead of blending,
                    // so a colour with alpha - every semantic one has some - came out solid
                    // (#380, A300).
                    if self.drawsBackground, let backgroundColor = self.backgroundColor {
                        backgroundColor.set()
                        imageFrame.fill(using: .sourceOver)
                    }
                    imageFrame.origin.x += 3
                    imageFrame.size = imageSize

                    imageFrame.origin.y += ceil((cellFrame.size.height - imageFrame.size.height) / 2)

                    lastImage.draw(at: imageFrame.origin, from: NSZeroRect, operation: .sourceOver, fraction: 1.0)
                }
            }
        } catch {
            if let localException = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException {
                _N2LogExceptionImpl(localException, true, "-[ImageAndTextCell drawWithFrame:inView:]")
            }
        }

        super.draw(withFrame: cellFrame, in: controlView)
    }

    public override var cellSize: NSSize {
        var cellSize = super.cellSize
        cellSize.width += (imageStorage != nil ? imageStorage!.size.width : 0) + 3
        return cellSize
    }
}
