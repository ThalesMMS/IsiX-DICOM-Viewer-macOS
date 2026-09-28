/*=========================================================================
 This file is part of the Horos Project (www.horosproject.org)
 
 Horos is free software: you can redistribute it and/or modify
 it under the terms of the GNU Lesser General Public License as published by
 the Free Software Foundation, Â version 3 of the License.
 
 The Horos Project was based originally upon the OsiriX Project which at the time of
 the code fork was licensed as a LGPL project.  However, not all of the the source-code
 was properly documented and file headers were not all updated with the appropriate
 license terms. The Horos Project, originally was licensed under the  GNU GPL license.
 However, contributors to the software since that time have agreed to modify the license
 to the GNU LGPL in order to be conform to the changes previously made to the
 OsiriX Project.
 
 Horos is distributed in the hope that it will be useful, but
 WITHOUT ANY WARRANTY EXPRESS OR IMPLIED, INCLUDING ANY WARRANTY OF
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE OR USE. Â See the
 GNU Lesser General Public License for more details.
 
 You should have received a copy of the GNU Lesser General Public License
 along with Horos. Â If not, see http://www.gnu.org/licenses/lgpl.html
 
 Prior versions of this file were published by the OsiriX team pursuant to
 the below notice and licensing protocol.
 ============================================================================
 Program: Â  OsiriX
 Â Copyright (c) OsiriX Team
 Â All rights reserved.
 Â Distributed under GNU - LGPL
 Â 
 Â See http://www.osirix-viewer.com/copyright.html for details.
 Â  Â  This software is distributed WITHOUT ANY WARRANTY; without even
 Â  Â  the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 Â  Â  PURPOSE.
 ============================================================================*/
//
//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS) — modifications in this fork

import Foundation

/// A database attribute (patient name, study date...) shown among the DICOM
/// tags of the smart album editor: its name is the key path the predicate
/// compares, its description the menu title, and its cskey the entry of
/// O2DicomPredicateEditorCodeStrings for a CS attribute.
///
/// Implemented in Swift since #713: the Objective-C name, the selectors
/// and <Horos/O2DicomPredicateEditorDCMAttributeTag.h> are those of the
/// former class. DCMAttributeTag stays in Objective-C.
@objc(O2DicomPredicateEditorDCMAttributeTag)
public final class O2DicomPredicateEditorDCMAttributeTag: DCMAttributeTag {
    private var _description: String?
    private var _cskey: String?

    @objc(tagWithGroup:element:vr:name:description:cskey:)
    public class func tag(withGroup group: Int32, element: Int32, vr: String!, name: String!, description: String!, cskey: String!) -> O2DicomPredicateEditorDCMAttributeTag {
        return O2DicomPredicateEditorDCMAttributeTag(group: group, element: element, vr: vr, name: name, description: description, cskey: cskey)
    }

    @objc(tagWithGroup:element:vr:name:description:)
    public class func tag(withGroup group: Int32, element: Int32, vr: String!, name: String!, description: String!) -> O2DicomPredicateEditorDCMAttributeTag {
        return O2DicomPredicateEditorDCMAttributeTag(group: group, element: element, vr: vr, name: name, description: description, cskey: nil)
    }

    /// As the former initializer, it sets the tag's instance variables after
    /// -[NSObject init], without the tag dictionary lookup of
    /// -initWithGroup:element:. DCMAttributeTag has no setter for group,
    /// element and name: key-value coding sets its _group, _element and _name
    /// variables, retaining the name as DCMAttributeTag's -dealloc expects.
    @objc(initWithGroup:element:vr:name:description:cskey:)
    public init(group: Int32, element: Int32, vr: String!, name: String!, description: String!, cskey: String!) {
        _description = description
        _cskey = cskey
        super.init()
        setValue(NSNumber(value: group), forKey: "group")
        setValue(NSNumber(value: element), forKey: "element")
        self.vr = vr
        setValue(name, forKey: "name")
    }

    // The initializers the former subclass inherited from DCMAttributeTag.

    public override init() {
        super.init()
    }

    public override init!(group: Int32, element: Int32) {
        super.init(group: group, element: element)
    }

    public override init!(tag: DCMAttributeTag!) {
        super.init(tag: tag)
    }

    public override init!(tagString: String!) {
        super.init(tagString: tagString)
    }

    public override init!(name: String!) {
        super.init(name: name)
    }

    public override var description: String {
        if let description = _description {
            return description
        }
        return super.description
    }

    @objc(cskey)
    public func cskey() -> String? {
        return _cskey
    }
}
