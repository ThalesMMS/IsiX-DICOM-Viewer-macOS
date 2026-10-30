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

/// The two dictionaries attribute tags are named with, built from the data
/// dictionary DCMTK loaded: "GGGG,EEEE" -> {Description, VR, VM}, and name ->
/// "GGGG,EEEE". The app's DCMTK adapter builds them (`HorosDICOMDictionaries`);
/// it is found by name, because no module may link the adapters. A process
/// without it has empty dictionaries, and says so once.
@objc(IsiXDICOMTagDictionary)
public final class DICOMTagDictionary: NSObject {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tags: NSDictionary?
    nonisolated(unsafe) private static var names: NSDictionary?

    private static func load(_ selector: String) -> NSDictionary {
        if let host = NSClassFromString("HorosDICOMDictionaries") as? NSObject.Type,
           host.responds(to: NSSelectorFromString(selector)),
           let dictionary = host.perform(NSSelectorFromString(selector))?.takeUnretainedValue() as? NSDictionary {
            return dictionary
        }
        NSLog("IsiXDICOMTagDictionary: no %@ in this process; it comes from the host's DCMTK", selector)
        return NSDictionary()
    }

    /// "GGGG,EEEE" -> {Description, VR, VM}.
    @objc public static func sharedTagDictionary() -> NSDictionary! {
        lock.lock(); defer { lock.unlock() }
        if let tags { return tags }
        let loaded = load("tagDictionary")
        tags = loaded
        return loaded
    }

    /// Name -> "GGGG,EEEE".
    @objc public static func sharedTagForNameDictionary() -> NSDictionary! {
        lock.lock(); defer { lock.unlock() }
        if let names { return names }
        let loaded = load("tagForNameDictionary")
        names = loaded
        return loaded
    }

    /// The other 2011 spelling of a keyword, or nil when the name has only one
    /// form: `PatientName` <-> `PatientsName`, `ReferringPhysicianName` <->
    /// `ReferringPhysiciansName`, only before Name, BirthDate, Sex, BirthName
    /// or Address.
    @objc(otherSpellingOfName:)
    public static func otherSpelling(of name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let text = name as NSString
        let words = ["Patient", "Physician"]
        func followedByCapital(_ range: NSRange) -> Bool {
            let after = range.location + range.length
            guard after < text.length else { return false }
            let character = text.character(at: after)
            return character >= 0x41 && character <= 0x5A
        }
        func is2011Suffix(_ after: Int) -> Bool {
            ["Name", "BirthDate", "Sex", "BirthName", "Address"].contains(text.substring(from: after))
        }
        for word in words {
            let range = text.range(of: word + "s")
            if range.location != NSNotFound && followedByCapital(range) && is2011Suffix(range.location + range.length) {
                return text.replacingCharacters(in: range, with: word)
            }
        }
        for word in words {
            let range = text.range(of: word)
            if range.location != NSNotFound && followedByCapital(range) && is2011Suffix(range.location + range.length) {
                return text.replacingCharacters(in: range, with: word + "s")
            }
        }
        return nil
    }
}

/// An attribute tag, (group, element), with the name and value representation
/// the dictionary gives it: "Unknown" and "UN" for a tag it does not know.
/// Tags compare and are equal by their "GGGG,EEEE" text.
@objc(IsiXDICOMAttributeTag)
open class DICOMAttributeTag: NSObject, NSCopying {
    @objc public let group: Int32
    @objc public let element: Int32
    @objc public private(set) var name: String?
    @objc public var vr: String?

    @objc(initWithGroup:element:)
    public init(group: Int32, element: Int32) {
        self.group = group
        self.element = element
        name = "Unknown"
        super.init()
        if let entry = DICOMTagDictionary.sharedTagDictionary().object(forKey: stringValue as String) as? NSDictionary {
            name = entry.object(forKey: "Description") as? String
            vr = entry.object(forKey: "VR") as? String
        }
        if vr == nil { vr = "UN" }
    }

    /// A tag named as given, without looking it up in the dictionary: an
    /// attribute of the database shown among the tags.
    @objc(initWithGroup:element:vr:name:)
    public init(group: Int32, element: Int32, vr: String?, name: String?) {
        self.group = group
        self.element = element
        self.name = name
        self.vr = vr
        super.init()
    }

    @objc(initWithTag:)
    public convenience init(tag: DICOMAttributeTag) {
        self.init(group: tag.group, element: tag.element)
    }

    /// "GGGG,EEEE", "(GGGG,EEEE)" or any text a hex group, a comma and a hex
    /// element can be scanned from. The name is looked up with the text as it
    /// is, parentheses left out: a tag written another way reads with no name.
    @objc(initWithTagString:)
    public init(tagString: String?) {
        if tagString == nil { NSLog("tagString == nil") }
        let text = (tagString ?? "").replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
        let scanner = Scanner(string: text)
        scanner.charactersToBeSkipped = .whitespacesAndNewlines
        let group = scanner.scanUInt64(representation: .hexadecimal) ?? 0
        _ = scanner.scanString(",")
        let element = scanner.scanUInt64(representation: .hexadecimal) ?? 0
        self.group = Int32(truncatingIfNeeded: group)
        self.element = Int32(truncatingIfNeeded: element)
        super.init()
        if let entry = DICOMTagDictionary.sharedTagDictionary().object(forKey: text) as? NSDictionary {
            name = entry.object(forKey: "Description") as? String
            vr = entry.object(forKey: "VR") as? String
        }
        if vr == nil { vr = "UN" }
    }

    /// The tag of a dictionary name, in either 2011 spelling; nil when the
    /// dictionary has no such name.
    @objc(initWithName:)
    public convenience init?(name: String?) {
        let names: NSDictionary = DICOMTagDictionary.sharedTagForNameDictionary()
        var tagString = name.flatMap { names.object(forKey: $0) as? String }
        if tagString == nil, let other = DICOMTagDictionary.otherSpelling(of: name) {
            tagString = names.object(forKey: other) as? String
        }
        guard let tagString else { return nil }
        self.init(tagString: tagString)
    }

    @objc(tagWithGroup:element:)
    open class func tag(withGroup group: Int32, element: Int32) -> DICOMAttributeTag! {
        DICOMAttributeTag(group: group, element: element)
    }

    @objc(tagWithTag:)
    open class func tag(with tag: DICOMAttributeTag) -> DICOMAttributeTag! {
        DICOMAttributeTag(tag: tag)
    }

    @objc(tagWithTagString:)
    open class func tag(withTagString tagString: String?) -> DICOMAttributeTag! {
        DICOMAttributeTag(tagString: tagString)
    }

    @objc(tagWithName:)
    open class func tag(withName name: String?) -> DICOMAttributeTag? {
        DICOMAttributeTag(name: name)
    }

    open func copy(with zone: NSZone? = nil) -> Any { DICOMAttributeTag(tag: self) }

    /// Odd groups are private.
    @objc public var isPrivate: Bool { group % 2 != 0 }

    /// "GGGG,EEEE", upper-case hexadecimal.
    @objc public var stringValue: String! { String(format: "%04X,%04X", group, element) }

    /// (group << 16) + element.
    @objc public var longValue: Int { (Int(group) << 16) + (Int(element) & 0xffff) }

    open override var description: String { "\(stringValue!)\t\(name ?? "(null)")\t\(vr ?? "(null)")" }

    /// The name, or the tag's text when it has none.
    @objc open func readableDescription() -> String {
        if let name, !name.isEmpty { return name }
        return stringValue
    }

    @objc(compare:)
    open func compare(_ tag: DICOMAttributeTag) -> ComparisonResult {
        (stringValue as NSString).compare(tag.stringValue)
    }

    @objc(isEquaToTag:)
    open func isEqual(toTag tag: DICOMAttributeTag?) -> Bool { tag?.stringValue == stringValue }

    open override func isEqual(_ object: Any?) -> Bool {
        guard let tag = object as? DICOMAttributeTag else { return false }
        return isEqual(toTag: tag)
    }

    open override var hash: Int { stringValue.hash }
}
