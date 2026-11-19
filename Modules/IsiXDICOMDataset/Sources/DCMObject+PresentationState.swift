//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import Foundation
import IsiXDICOMFile

// The accessors of a presentation state the plugin SDK of Horos and OsiriX
// declared on a DICOM object: its sequences, its rotation and flip, and what a
// graphic or text object of its annotations says. They read the attributes by
// name, as they did; a plugin built for that SDK still sends them.
extension DCMObject {
    private func items(of name: String, in object: DCMObject? = nil) -> [Any]? {
        ((object ?? self).attribute(withName: name) as? DCMSequenceAttribute)?.sequenceItems as? [Any]
    }

    private static func text(_ name: String, of object: DCMObject?) -> String? {
        object?.attributeValue(withName: name) as? String
    }

    /// The two values of `name` as a point; zero when there are not two.
    private static func point(_ name: String, of object: DCMObject?) -> NSPoint {
        guard let values = object?.attribute(withName: name)?.values, values.count == 2 else { return .zero }
        func number(_ value: Any) -> CGFloat { CGFloat((value as? NSNumber)?.floatValue ?? (value as? NSString)?.floatValue ?? 0) }
        return NSPoint(x: number(values[0]), y: number(values[1]))
    }

    private static func integer(_ value: Any?) -> Int32 {
        (value as? NSNumber)?.int32Value ?? (value as? NSString)?.intValue ?? 0
    }

    @objc(isPresentationState) public func sdkIsPresentationState() -> Bool {
        DICOMSOPClass.isPresentationState(attributeValue(withName: "SOPClassUID") as? String)
    }

    @objc(graphicAnnotationSequence) public func sdkGraphicAnnotationSequence() -> [Any]? { items(of: "GraphicAnnotationSequence") }
    @objc(graphicObjectSequence) public func sdkGraphicObjectSequence() -> [Any]? { items(of: "GraphicObjectSequence") }
    @objc(displayedAreaSelectionSequence) public func sdkDisplayedAreaSelectionSequence() -> [Any]? { items(of: "DisplayedAreaSelectionSequence") }
    @objc(graphicLayerSequence) public func sdkGraphicLayerSequence() -> [Any]? { items(of: "GraphicLayerSequence") }
    @objc(softcopyVOILUTSequence) public func sdkSoftcopyVOILUTSequence() -> [Any]? { items(of: "SoftcopyVOILUTSequence") }
    @objc(imageRotation) public func sdkImageRotation() -> Int32 { Self.integer(attributeValue(withName: "ImageRotation")) }
    @objc(horizontalFlip) public func sdkHorizontalFlip() -> Bool { Self.text("ImageHorizontalFlip", of: self) == "Y" }

    @objc(anchorPointForGraphicsObject:) public func sdkAnchorPoint(forGraphicsObject object: DCMObject?) -> NSPoint {
        Self.point("AnchorPoint", of: object)
    }
    @objc(anchorPointVisibiltyForGraphicsObject:) public func sdkAnchorPointVisibility(forGraphicsObject object: DCMObject?) -> Bool {
        Self.text("AnchorPointVisibility", of: object) == "Y"
    }
    @objc(anchorPointAnnotationUnitsIsPixelForGraphicsObject:)
    public func sdkAnchorPointAnnotationUnitsIsPixel(forGraphicsObject object: DCMObject?) -> Bool {
        Self.text("AnchorPointAnnotationUnits", of: object) == "PIXEL"
    }
    @objc(boundingBoxTopLeftHandCornerForObject:) public func sdkBoundingBoxTopLeftHandCorner(for object: DCMObject?) -> NSPoint {
        Self.point("BoundingBoxTopLeftHandCorner", of: object)
    }
    @objc(boundingBoxBottomRightHandCornerForObject:) public func sdkBoundingBoxBottomRightHandCorner(for object: DCMObject?) -> NSPoint {
        Self.point("BoundingBoxBottomRightHandCorner", of: object)
    }
    @objc(boundingBoxTextHorizontalJustificationForObject:)
    public func sdkBoundingBoxTextHorizontalJustification(for object: DCMObject?) -> String? {
        Self.text("BoundingBoxTextHorizontalJustification", of: object)
    }
    @objc(textObjectSequenceForObject:) public func sdkTextObjectSequence(for object: DCMObject?) -> [Any]? {
        object.flatMap { items(of: "TextObjectSequence", in: $0) }
    }
    @objc(graphicObjectSequenceForObject:) public func sdkGraphicObjectSequence(for object: DCMObject?) -> [Any]? {
        object.flatMap { items(of: "GraphicObjectSequence", in: $0) }
    }
    @objc(unformattedTextValueForObject:) public func sdkUnformattedTextValue(for object: DCMObject?) -> String? {
        Self.text("UnformattedTextValue", of: object)
    }
    /// The name of the attribute is spelt as that SDK spelt it.
    @objc(numberOfGraphicPointsForGraphicsObject:) public func sdkNumberOfGraphicPoints(forGraphicsObject object: DCMObject?) -> Int32 {
        Self.integer(object?.attributeValue(withName: "NumberofGraphicPoints"))
    }
    @objc(graphicDataForGraphicsObject:) public func sdkGraphicData(forGraphicsObject object: DCMObject?) -> [Any]? {
        object?.attribute(withName: "GraphicData")?.values as? [Any]
    }
    @objc(graphicTypeForGraphicsObject:) public func sdkGraphicType(forGraphicsObject object: DCMObject?) -> String? {
        Self.text("GraphicType", of: object)
    }
    @objc(graphicFilledForGraphicsObject:) public func sdkGraphicFilled(forGraphicsObject object: DCMObject?) -> Bool {
        Self.text("GraphicFilled", of: object) == "Y"
    }
}
