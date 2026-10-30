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

/// A parsed DICOM data set, or one item of a sequence in it, as the image
/// attribute reading asks it for values.
///
/// The app's parsed object (`DCMObject`, wrapping DCMTK) answers the first four
/// requirements with the methods it already has; the fifth is added beside it,
/// in the app, so that this module never needs to know the parser's classes.
/// A value is whatever class the parser chose for the value representation the
/// file declared: usually `NSNumber` or `NSString`, `NSData` for bytes, a date
/// object for DA/TM, so the reading treats each one as Objective-C would.
@objc(IsiXDICOMAttributeSource)
public protocol DICOMAttributeSource: NSObjectProtocol {
    /// The first value of the attribute with this dictionary name, or nil.
    @objc(attributeValueWithName:)
    func attributeValue(withName name: String) -> Any?

    /// Every value of the attribute with this dictionary name, or nil.
    @objc(attributeArrayWithName:)
    func attributeArray(withName name: String) -> [Any]?

    /// The first value of the attribute stored under a tag key such as `6000,3000`.
    @objc(attributeValueForKey:)
    func attributeValue(forKey key: String) -> Any?

    /// Every value of the attribute stored under a tag key.
    @objc(attributeArrayForKey:)
    func attributeArray(forKey key: String) -> [Any]?

    /// The items of the sequence with this dictionary name: nil when the data
    /// set has no such attribute, an array of items (sources themselves) when
    /// it is a sequence, and the attribute object itself when it is there but
    /// is not a sequence.
    @objc(isixSequenceItemsWithName:)
    func sequenceItems(withName name: String) -> Any?
}

/// The items of a sequence, taken from the parser's array one at a time: a
/// frame of an enhanced object reads one item of a per-frame sequence that
/// has one for every frame.
struct SequenceItems: RandomAccessCollection {
    let array: NSArray

    var startIndex: Int { 0 }
    var endIndex: Int { array.count }

    subscript(index: Int) -> DICOMAttributeSource {
        array.object(at: index) as? DICOMAttributeSource ?? EmptyAttributeSource()
    }
}

/// An item that answers nothing, for an array element that is not a data set.
final class EmptyAttributeSource: NSObject, DICOMAttributeSource {
    func attributeValue(withName name: String) -> Any? { nil }
    func attributeArray(withName name: String) -> [Any]? { nil }
    func attributeValue(forKey key: String) -> Any? { nil }
    func attributeArray(forKey key: String) -> [Any]? { nil }
    func sequenceItems(withName name: String) -> Any? { nil }
}

/// What a sequence lookup found.
enum SequenceLookup {
    case absent
    /// The attribute is there and is not a sequence; asking it for its items
    /// is what Objective-C refused.
    case notASequence(AnyObject)
    case items(SequenceItems)

    init(_ answer: Any?) {
        guard let answer else {
            self = .absent
            return
        }
        if let array = answer as? NSArray {
            self = .items(SequenceItems(array: array))
        } else {
            self = .notASequence(answer as AnyObject)
        }
    }
}

extension DICOMAttributeSource {
    func sequence(named name: String) -> SequenceLookup {
        SequenceLookup(sequenceItems(withName: name))
    }

    /// The first item of a sequence, the way `[[seq sequence] objectAtIndex:0]`
    /// answered it: nothing when the attribute is absent, and an exception when
    /// it is not a sequence or has no item.
    func firstItem(ofSequence name: String) throws -> DICOMAttributeSource? {
        switch sequence(named: name) {
        case .absent:
            return nil
        case .notASequence(let attribute):
            throw AttributeReadException.unrecognizedSelector("sequence", sentTo: attribute)
        case .items(let items):
            guard let first = items.first else {
                throw AttributeReadException.beyondBounds(index: 0, count: 0)
            }
            return first
        }
    }
}
