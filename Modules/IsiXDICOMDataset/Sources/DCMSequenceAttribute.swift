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
import IsiXDICOMFile

/// A sequence: its items are DCMObjects, each kept with the offset it was
/// read at (`sequenceItems` holds {item, offset} dictionaries).
@objc(IsiXDCMSequenceAttribute)
public final class DCMSequenceAttribute: DCMAttribute {

    @objc public var sequenceItems: NSMutableArray! = NSMutableArray()

    // MARK: For structured reports

    @objc public class func contentSequence() -> DCMSequenceAttribute {
        sequenceAttribute(withName: "ContentSequence")
    }

    @objc(conceptNameCodeSequenceWithCodeValue:codeSchemeDesignator:codeMeaning:)
    public class func conceptNameCodeSequence(withCodeValue codeValue: String, codeSchemeDesignator: String,
                                              codeMeaning: String) -> DCMSequenceAttribute {
        let sequence = sequenceAttribute(withName: "ConceptNameCodeSequence")
        let item = DCMObject.dcmObject()
        item.setAttributeValues(NSMutableArray(object: codeValue), forName: "CodeValue")
        item.setAttributeValues(NSMutableArray(object: codeSchemeDesignator), forName: "CodingSchemeDesignator")
        item.setAttributeValues(NSMutableArray(object: codeMeaning), forName: "CodeMeaning")
        sequence.addItem(item)
        return sequence
    }

    @objc(sequenceAttributeWithName:)
    public class func sequenceAttribute(withName name: String) -> DCMSequenceAttribute {
        DCMSequenceAttribute(attributeTag: DICOMAttributeTag.tag(withName: name))
    }

    public override init(attributeTag tag: DICOMAttributeTag?, vr: String?, values: NSMutableArray?) {
        super.init(attributeTag: tag, vr: vr, values: values)
    }

    // MARK: Items

    @objc(addItem:)
    public func addItem(_ item: Any) {
        addItem(item, offset: 0)
    }

    @objc(addItem:offset:)
    public func addItem(_ item: Any, offset: Int) {
        sequenceItems?.add(["item": item, "offset": NSNumber(value: Int32(truncatingIfNeeded: offset))])
    }

    /// The items alone.
    @objc public var sequence: [Any]! {
        (sequenceItems ?? NSMutableArray()).compactMap { ($0 as? NSDictionary)?["item"] }
    }

    /// A sequence has no value length of its own.
    @objc public override var valueLength: Int { 0xFFFFFFFF }

    // MARK: Descriptions

    @objc public override func readableDescription() -> String {
        var description = super.readableDescription()
        for entry in sequenceItems ?? NSMutableArray() {
            guard let item = (entry as? NSDictionary)?["item"] as? DCMObject else { break }
            description = "\(description)\n\t\(item.readableDescription())"
        }
        return description
    }

    public override var description: String {
        var description = super.description
        for entry in sequenceItems ?? NSMutableArray() {
            guard let item = (entry as? NSDictionary)?["item"] as? NSObject else { break }
            description = "\(description)\n\t\(item.description)"
        }
        return description
    }

    @objc public override func xmlNode() -> XMLNode {
        var elements: [XMLNode] = []
        for entry in sequenceItems ?? NSMutableArray() {
            if let item = (entry as? NSDictionary)?["item"] as? DCMObject {
                elements.append(item.xmlNode())
            }
        }
        let tag = attrTag!
        let name = (tag.name ?? "").replacingOccurrences(of: "/", with: "_")
        let attributes = [XMLNode.attribute(withName: "group", stringValue: String(format: "%04x", tag.group)),
                          XMLNode.attribute(withName: "element", stringValue: String(format: "%04x", tag.element)),
                          XMLNode.attribute(withName: "vr", stringValue: tag.vr ?? "")]
        return XMLNode.element(withName: name, children: elements, attributes: attributes as? [XMLNode]) as! XMLNode
    }
}
