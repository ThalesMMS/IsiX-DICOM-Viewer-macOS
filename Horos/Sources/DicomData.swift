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

import Foundation

/// Tree node for xml.
///
/// Implemented in Swift: the Objective-C name, the selectors and
/// <Horos/DicomData.h> are those of the former class. As before, the node
/// does not retain its parent node nor the two arrays (`weak`, which reads nil
/// once they are gone), and keeps the strings it is given (not copies, hence
/// NSString).
@objc(dicomData)
public final class dicomData: NSObject {
    private weak var _parentData: dicomData?
    private weak var _parent: NSMutableArray?
    private weak var _child: NSMutableArray?
    private var _group: NSString?
    private var _name: NSString?
    private var _tagName: NSString?
    private var _content: NSString?

    @objc public override init() {
        super.init()
    }

    @objc(parentData)
    public func parent() -> dicomData! {
        return _parentData
    }

    @objc(setParentData:)
    public func setParent(_ p: dicomData!) {
        _parentData = p
    }

    @objc(parent)
    public func parent() -> NSMutableArray! {
        return _parent
    }

    @objc(setParent:)
    public func setParent(_ p: NSMutableArray!) {
        _parent = p
    }

    @objc(child)
    public func child() -> NSMutableArray! {
        return _child
    }

    @objc(setChild:)
    public func setChild(_ p: NSMutableArray!) {
        _child = p
    }

    @objc(group)
    public func group() -> NSString! {
        return _group
    }

    @objc(setGroup:)
    public func setGroup(_ s: NSString!) {
        _group = s
    }

    @objc(name)
    public func name() -> NSString! {
        return _name
    }

    @objc(setName:)
    public func setName(_ s: NSString!) {
        _name = s
    }

    @objc(tagName)
    public func tagName() -> NSString! {
        return _tagName
    }

    @objc(setTagName:)
    public func setTagName(_ s: NSString!) {
        _tagName = s
    }

    @objc(content)
    public func content() -> NSString! {
        return _content
    }

    @objc(setContent:)
    public func setContent(_ s: NSString!) {
        _content = s
    }
}
