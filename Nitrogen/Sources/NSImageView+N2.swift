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

// NSImageView (N2) is implemented in Swift since #709; the selectors and
// <Horos/NSImageView+N2.h> are those of the former category.

public extension NSImageView {

    @objc(createWithImage:)
    class func create(with image: NSImage?) -> AnyObject? {
        // [[self alloc] initWithSize:], for whatever subclass receives the
        // message: Swift constructs `Self` only through a required initializer,
        // so both messages go through the runtime. -alloc returns the object
        // retained and -initWithSize: consumes it and returns it retained.
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initWithSize:")
        typealias Alloc = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        typealias InitWithSize = @convention(c) (UnsafeMutableRawPointer, Selector, NSSize) -> UnsafeMutableRawPointer?
        guard let allocImplementation = class_getMethodImplementation(object_getClass(self), allocSelector),
              let initImplementation = class_getMethodImplementation(self, initSelector),
              let allocated = unsafeBitCast(allocImplementation, to: Alloc.self)(self, allocSelector),
              let initialized = unsafeBitCast(initImplementation, to: InitWithSize.self)(allocated, initSelector, image?.size ?? .zero)
        else { return nil }
        let view = Unmanaged<NSImageView>.fromOpaque(initialized).takeRetainedValue()
        view.image = image
        return view
    }

    /// Not in the header: N2CellDescriptor and N2 layouts send it.
    @objc func optimalSize() -> NSSize {
        let size = image?.size ?? .zero
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }

    /// Not in the header: N2CellDescriptor and N2 layouts send it.
    @objc(optimalSizeForWidth:)
    func optimalSize(forWidth width: CGFloat) -> NSSize {
        let imageSize = image?.size ?? .zero
        var width = width
        if width == CGFloat.greatestFiniteMagnitude { width = imageSize.width }
        return NSSize(width: ceil(width), height: ceil(width / imageSize.width * imageSize.height))
    }
}
