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

/// Describes a cell of an N2ColumnLayout: its view, alignment, width
/// constraints, column span, invasivity and whether it fills the cell.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// `<Horos/N2CellDescriptor.h>` are those of the former class. Open because
/// N2ColumnDescriptor subclasses it.
///
/// The former header took the width constraints as `const N2MinMax&`. A C++
/// reference is passed as a pointer, so the methods here take
/// `UnsafePointer<N2MinMax>`: the selectors and the calling convention do not
/// change.
// Main actor: the views of an N2ColumnLayout row, laid out on the main thread.
@MainActor
@available(*, deprecated)
@objc(N2CellDescriptor)
open class N2CellDescriptor: NSObject, @MainActor NSCopying {
    @objc public var view: NSView?
    @objc public var alignment: N2Alignment
    @objc public var widthConstraints: N2MinMax
    // @property NSUInteger rowSpan;
    @objc public var colSpan: UInt = 0
    @objc public var invasivity: CGFloat = 0
    @objc public var filled = false

    @objc(descriptor)
    public class func descriptor() -> N2CellDescriptor {
        self.init().withColSpan(1)
    }

    @objc(descriptorWithView:)
    public class func descriptor(view: NSView?) -> N2CellDescriptor {
        descriptor().withView(view)
    }

    @objc(descriptorWithWidthConstraints:)
    public class func descriptor(widthConstraints: UnsafePointer<N2MinMax>) -> N2CellDescriptor {
        descriptor().withWidthConstraints(widthConstraints)
    }

    @objc(descriptorWithWidthConstraints:alignment:)
    public class func descriptor(widthConstraints: UnsafePointer<N2MinMax>, alignment: N2Alignment) -> N2CellDescriptor {
        descriptor(widthConstraints: widthConstraints).withAlignment(alignment)
    }

    @objc public required override init() {
        widthConstraints = N2MinMax(min: N2NoMin, max: N2NoMax)
        alignment = N2Left
        filled = true
        super.init()
    }

    /// Deprecated in the former header. Unlike -init, it leaves -filled NO.
    @available(*, deprecated)
    @objc(initWithWidthConstraints:alignment:)
    public init(widthConstraints: UnsafePointer<N2MinMax>, alignment: N2Alignment) {
        self.widthConstraints = widthConstraints.pointee
        self.alignment = alignment
        super.init()
    }

    /// Copies are N2CellDescriptor even for a subclass, as before.
    @objc(copyWithZone:)
    public func copy(with zone: NSZone? = nil) -> Any {
        let copy = withUnsafePointer(to: widthConstraints) {
            N2CellDescriptor(widthConstraints: $0, alignment: alignment)
        }
        copy.view = view
        copy.alignment = alignment
        copy.widthConstraints = widthConstraints
        copy.invasivity = invasivity
        copy.colSpan = colSpan
        copy.filled = filled
        return copy
    }

    @objc(view:) @discardableResult
    public func withView(_ view: NSView?) -> N2CellDescriptor {
        self.view = view
        return self
    }

    @objc(alignment:) @discardableResult
    public func withAlignment(_ alignment: N2Alignment) -> N2CellDescriptor {
        self.alignment = alignment
        return self
    }

    @objc(widthConstraints:) @discardableResult
    public func withWidthConstraints(_ widthConstraints: UnsafePointer<N2MinMax>) -> N2CellDescriptor {
        self.widthConstraints = widthConstraints.pointee
        return self
    }

    // -(N2CellDescriptor*)rowSpan:(NSUInteger)rowSpan;

    @objc(colSpan:) @discardableResult
    public func withColSpan(_ colSpan: UInt) -> N2CellDescriptor {
        self.colSpan = colSpan
        return self
    }

    @objc(invasivity:) @discardableResult
    public func withInvasivity(_ invasivity: CGFloat) -> N2CellDescriptor {
        self.invasivity = invasivity
        return self
    }

    @objc(filled:) @discardableResult
    public func withFilled(_ filled: Bool) -> N2CellDescriptor {
        self.filled = filled
        return self
    }

    @objc public func optimalSize() -> NSSize {
        if let view, view.responds(to: optimalSizeSelector) {
            return ceilSize(sendSize(view, optimalSizeSelector))
        }
        return view?.frame.size ?? .zero
    }

    @objc(optimalSizeForWidth:)
    public func optimalSize(forWidth width: CGFloat) -> NSSize {
        if let view, view.responds(to: optimalSizeForWidthSelector) {
            return ceilSize(sendSize(view, optimalSizeForWidthSelector, width))
        }
        return ceilSize(view?.frame.size ?? .zero)
    }

    @objc public func sizeAdjust() -> NSRect {
        view?.sizeAdjust() ?? .zero
    }
}

/// Declared in the same header as N2CellDescriptor, and like it deprecated.
@available(*, deprecated)
@objc(N2ColumnDescriptor)
public final class N2ColumnDescriptor: N2CellDescriptor {
}

private let optimalSizeSelector = NSSelectorFromString("optimalSize")
private let optimalSizeForWidthSelector = NSSelectorFromString("optimalSizeForWidth:")

/// Sends -optimalSize to any view that responds to it, as the former
/// `[(id<OptimalSize>)_view optimalSize]` did, whether or not the view's class
/// declares the protocol.
private func sendSize(_ object: NSObject, _ selector: Selector) -> NSSize {
    typealias Send = @convention(c) (NSObject, Selector) -> NSSize
    return unsafeBitCast(object.method(for: selector), to: Send.self)(object, selector)
}

private func sendSize(_ object: NSObject, _ selector: Selector, _ width: CGFloat) -> NSSize {
    typealias Send = @convention(c) (NSObject, Selector, CGFloat) -> NSSize
    return unsafeBitCast(object.method(for: selector), to: Send.self)(object, selector, width)
}

/// n2::ceil of N2Operators.
private func ceilSize(_ size: NSSize) -> NSSize {
    NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
}
