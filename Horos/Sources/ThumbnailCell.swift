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

fileprivate let FULLSIZEHEIGHT: Float = 120
fileprivate let HALFSIZEHEIGHT: Float = 60
fileprivate let SIZEWIDTH: Double = 100

/// [value boolValue] on an id: NO for nil.
fileprivate func objcBoolValue(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if let string = value as? NSString { return string.boolValue }
    return false
}

/// The cell of the viewer's series and studies thumbnails matrix.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors and
/// <Horos/ThumbnailCell.h> are those of the former class, and Viewer.xib uses
/// the name as customClass. The cell has no object references of its own, so
/// NSCell's bitwise copy (NSCopyObject) needs no fixing: the flags are copied
/// as they were.
@objc(ThumbnailCell)
public final class ThumbnailCell: NSButtonCell {
    /// Atomic and readonly in the former header.
    @objc public private(set) var rightClick = false
    private var invertedSet = false
    private var invertedColors = false

    @objc public class func thumbnailCellWidth() -> Float {
        switch UserDefaults.standard.integer(forKey: "dbFontSize") {
        case -1: return Float(SIZEWIDTH * 0.8)
        case 0: return Float(SIZEWIDTH)
        case 1: return Float(SIZEWIDTH * 1.3)
        default: break
        }

        return Float(SIZEWIDTH)
    }

    public override func menu(for anEvent: NSEvent, in cellFrame: NSRect, of aView: NSView) -> NSMenu? {
        // [self retain] ... [self autorelease]: the click may release the cell.
        withExtendedLifetime(self) {
            rightClick = true
            self.performClick(self)
            rightClick = false
        }
        return nil
    }

    public override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        super.drawBezel(withFrame: frame, in: controlView)

        if let backgroundColor = self.backgroundColor {
            if !invertedSet {
                invertedColors = objcBoolValue(UserDefaults.standard.persistentDomain(forName: "com.apple.CoreGraphics")?["DisplayUseInvertedPolarity"])
            }

            var backc = backgroundColor.copy() as! NSColor

            if invertedColors {
                backc = NSColor(calibratedRed: 1.0 - backc.redComponent, green: 1.0 - backc.greenComponent, blue: 1.0 - backc.blueComponent, alpha: backc.alphaComponent)
            }

            NSGraphicsContext.saveGraphicsState()
            backc.withAlphaComponent(0.75).setFill()
            NSBezierPath.fill(NSInsetRect(frame, 1, 1))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    public override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        return super.drawTitle(title, withFrame: NSInsetRect(frame, -2, 0), in: controlView) // very precioussss 4px/pt
    }

    public override var cellSize: NSSize {
        let oro = self.representedObject as? O2ViewerThumbnailsMatrixRepresentedObject

        var h: Float = 0

        if oro?.object is NSManagedObject || (oro?.children?.count ?? 0) != 0 || oro == nil {
            h = FULLSIZEHEIGHT
        } else {
            h = HALFSIZEHEIGHT
        }

        switch UserDefaults.standard.integer(forKey: "dbFontSize") {
        case -1: return NSMakeSize(CGFloat(ThumbnailCell.thumbnailCellWidth()), CGFloat(Double(h) * 0.8))
        case 0: return NSMakeSize(CGFloat(ThumbnailCell.thumbnailCellWidth()), CGFloat(h))
        case 1: return NSMakeSize(CGFloat(ThumbnailCell.thumbnailCellWidth()), CGFloat(Double(h) * 1.3))
        default: break
        }

        return NSMakeSize(CGFloat(ThumbnailCell.thumbnailCellWidth()), CGFloat(h))
    }
}
