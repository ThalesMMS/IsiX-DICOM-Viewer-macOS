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

// NSAttributedString (Geometrics) and NSString (Geometrics) are implemented in
// Swift since #709; the selectors and <Horos/NS(Attributed)String+Geometrics.h>
// are those of the former categories. The global
// gNSStringGeometricsTypesetterBehavior stays a C variable, defined in
// NS(Attributed)String+Geometrics+CAPI.m; its header explains how it is used.

fileprivate let latestTypesetterBehavior = Int32(NSLayoutManager.TypesetterBehavior.latestBehavior.rawValue)

public extension NSAttributedString {

    // MARK: Measure Attributed String

    @objc(sizeForWidth:height:)
    func size(forWidth width: Float, height: Float) -> NSSize {
        var answer = NSSize.zero
        if length > 0 {
            // Checking for empty string is necessary since Layout Manager will give the nominal
            // height of one line if length is 0.  Our API specifies 0.0 for an empty string.
            let size = NSSize(width: CGFloat(width), height: CGFloat(height))
            let textContainer = NSTextContainer(size: size)
            let textStorage = NSTextStorage(attributedString: self)
            let layoutManager = NSLayoutManager()
            layoutManager.addTextContainer(textContainer)
            textStorage.addLayoutManager(layoutManager)
            layoutManager.hyphenationFactor = 0.0
            if gNSStringGeometricsTypesetterBehavior != latestTypesetterBehavior,
               let behavior = NSLayoutManager.TypesetterBehavior(rawValue: Int(gNSStringGeometricsTypesetterBehavior)) {
                layoutManager.typesetterBehavior = behavior
            }
            // NSLayoutManager is lazy, so we need the following kludge to force layout:
            _ = layoutManager.glyphRange(for: textContainer)

            answer = layoutManager.usedRect(for: textContainer).size

            // In case we changed it above, set typesetterBehavior back
            // to the default value.
            gNSStringGeometricsTypesetterBehavior = latestTypesetterBehavior
        }

        return answer
    }

    @objc(heightForWidth:)
    func height(forWidth width: Float) -> Float {
        Float(size(forWidth: width, height: .greatestFiniteMagnitude).height)
    }

    @objc(widthForHeight:)
    func width(forHeight height: Float) -> Float {
        Float(size(forWidth: .greatestFiniteMagnitude, height: height).width)
    }
}

public extension NSString {

    // MARK: Given String with Attributes

    @objc(sizeForWidth:height:attributes:)
    func size(forWidth width: Float, height: Float, attributes: [NSAttributedString.Key: Any]?) -> NSSize {
        let astr = NSAttributedString(string: self as String, attributes: attributes)
        return astr.size(forWidth: width, height: height)
    }

    @objc(heightForWidth:attributes:)
    func height(forWidth width: Float, attributes: [NSAttributedString.Key: Any]?) -> Float {
        Float(size(forWidth: width, height: .greatestFiniteMagnitude, attributes: attributes).height)
    }

    @objc(widthForHeight:attributes:)
    func width(forHeight height: Float, attributes: [NSAttributedString.Key: Any]?) -> Float {
        Float(size(forWidth: .greatestFiniteMagnitude, height: height, attributes: attributes).width)
    }

    // MARK: Given String with Font

    @objc(sizeForWidth:height:font:)
    func size(forWidth width: Float, height: Float, font: NSFont?) -> NSSize {
        var answer = NSSize.zero

        if let font {
            answer = size(forWidth: width, height: height, attributes: [.font: font])
        } else {
            NSLog("[%@]: Error: cannot compute size with nil font", NSStringFromClass(type(of: self)))
        }
        return answer
    }

    @objc(heightForWidth:font:)
    func height(forWidth width: Float, font: NSFont?) -> Float {
        Float(size(forWidth: width, height: .greatestFiniteMagnitude, font: font).height)
    }

    @objc(widthForHeight:font:)
    func width(forHeight height: Float, font: NSFont?) -> Float {
        Float(size(forWidth: .greatestFiniteMagnitude, height: height, font: font).width)
    }
}
