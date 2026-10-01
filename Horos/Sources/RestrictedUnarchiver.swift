//  Copyright (c) 2026 Thales Matheus M Santos (ThalesMMS)
//
//  This file is part of a fork of Horos (https://github.com/ThalesMMS/horos).
//
//  It is free software: you can redistribute it and/or modify it under the
//  terms of the GNU Lesser General Public License as published by the Free
//  Software Foundation, version 3 of the License.
//
//  It is distributed in the hope that it will be useful, but WITHOUT ANY
//  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
//  A PARTICULAR PURPOSE. See the GNU Lesser General Public License for details.

import AppKit

/// Why an archive was not unarchived.
public enum RestrictedUnarchiverError: Error, CustomStringConvertible {
    /// The archive names a class outside the list its reader accepts.
    case disallowedClass(String)
    /// The data is not an NSArchiver typedstream this reader can walk, or
    /// NSUnarchiver raised while decoding it.
    case unreadable(String)
    /// The archive decoded, but what it holds is not the value its reader
    /// expects: a wrong type, or a value outside its domain.
    case invalidValue(String)

    public var description: String {
        switch self {
        case .disallowedClass(let name):
            return "the archive names the class \(name), which this archive does not hold"
        case .unreadable(let reason), .invalidValue(let reason):
            return reason
        }
    }
}

/// Reads NSArchiver typedstreams - the ROI format of SRs, .roi and
/// .rois_series files and the ROI pasteboard, the CLUT editor's pasteboard
/// types, the 16-bit CLUT files of earlier versions and the values
/// N2UserDefaults archives - without letting the archive choose which classes
/// are instantiated. The albums' sort descriptors, a keyed archive, are read
/// here too, with secure coding, and the 16-bit CLUTs of property lists are
/// checked here as the legacy CLUT files are.
///
/// NSUnarchiver has no secure coding and no hook before it resolves a class:
/// the archive names the classes, and each one's -initWithCoder: runs. So the
/// whole stream is walked first, as NSUnarchiver would read it, and every class
/// name in it - of objects, of their superclasses and of class values - must be
/// on the caller's list. Only then does NSUnarchiver decode it. The walk
/// follows the type string that precedes every value in the stream, and
/// NSUnarchiver raises when that string is not the type the decoder asks for,
/// so the two cannot read the bytes differently; anything the walk does not
/// understand is refused rather than skipped. The format itself is unchanged,
/// so the archives Horos and OsiriX have written stay readable.
@objc(HorosRestrictedUnarchiver)
public final class RestrictedUnarchiver: NSObject {

    /// An array of ROIs (an SR, a .roi file, the ROI pasteboard) or of arrays
    /// of them (a .rois_series file): the classes ROI and its subclass
    /// HorosVolumeLengthROI archive, MyPoint, and the Foundation and AppKit
    /// values they hold.
    @objc public static let roiClassNames: Set<String> = [
        "ROI", "HorosVolumeLengthROI", "MyPoint",
        "NSObject", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
        "NSString", "NSMutableString", "NSNumber", "NSValue", "NSData", "NSMutableData", "NSColor",
    ]

    /// A curve of the CLUT and opacity editor: a dictionary of its points
    /// (NSValues) and their colours.
    @objc public static let clutCurveClassNames: Set<String> = [
        "NSObject", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
        "NSString", "NSMutableString", "NSNumber", "NSValue", "NSColor",
    ]

    /// One colour of the CLUT and opacity editor. A named colour holds strings.
    @objc public static let colorClassNames: Set<String> = [
        "NSObject", "NSColor", "NSString", "NSMutableString",
    ]

    /// The class names `data` holds, in the order they appear, or an error
    /// when it is not a typedstream this reader can walk.
    public static func classNames(in data: Data) throws -> [String] {
        var walker = TypedStreamWalker(bytes: [UInt8](data))
        try walker.walkRootObject()
        return walker.classNames
    }

    /// The root object of `data`, decoded by NSUnarchiver only when every
    /// class the archive names is in `allowedClassNames`.
    public static func unarchiveObject(with data: Data, allowedClassNames: Set<String>) throws -> Any {
        let mappingSelector = NSSelectorFromString("classNameDecodedForArchiveClassName:")
        let decodeSelector = NSSelectorFromString("unarchiveObjectWithData:")
        guard let reader = NSClassFromString("NSUnarchiver") as? NSObject.Type,
              reader.responds(to: mappingSelector), reader.responds(to: decodeSelector) else {
            throw RestrictedUnarchiverError.unreadable("the historical typedstream reader is unavailable")
        }
        for name in try classNames(in: data) {
            // A name must also reach NSUnarchiver as itself, not mapped to
            // another class by +decodeClassName:asClassName:.
            if !allowedClassNames.contains(name) ||
                reader.perform(mappingSelector, with: name)?.takeUnretainedValue() as? String != name {
                throw RestrictedUnarchiverError.disallowedClass(name)
            }
        }
        var object: Any?
        do {
            try HorosObjCException.perform {
                object = reader.perform(decodeSelector, with: data)?.takeUnretainedValue()
            }
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            throw RestrictedUnarchiverError.unreadable(exception?.reason ?? exception?.name.rawValue ?? "NSUnarchiver raised")
        }
        guard let object else {
            throw RestrictedUnarchiverError.unreadable("the archive holds no object")
        }
        return object
    }

    /// The object of an archive, or nil - logged - when it is refused or
    /// unreadable. What NSUnarchiver would raise for is answered with nil too.
    /// No data, or none at all (an image without ROIs), is nil without a word.
    @objc(unarchiveObjectWithData:allowedClassNames:)
    public static func unarchiveObjectOrNil(with data: Data?, allowedClassNames: Set<String>) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        do {
            return try unarchiveObject(with: data, allowedClassNames: allowedClassNames)
        } catch {
            NSLog("Refused to unarchive %lu bytes: %@", data.count, "\(error)")
            return nil
        }
    }

    /// The ROIs of an SR or of the ROI pasteboard: the array the archive
    /// holds, or nil when it is refused, unreadable or holds no array.
    @objc(unarchiveROIsWithData:)
    public static func unarchiveROIs(with data: Data?) -> NSArray? {
        return unarchiveObjectOrNil(with: data, allowedClassNames: roiClassNames) as? NSArray
    }

    /// The ROIs of a .roi or .rois_series file, as `unarchiveROIs(with:)`.
    @objc(unarchiveROIsWithFile:)
    public static func unarchiveROIs(withFile path: String?) -> NSArray? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        return unarchiveROIs(with: data)
    }

    // MARK: - 16-bit CLUTs of earlier versions

    /// A 16-bit CLUT as earlier versions saved it, a file without extension
    /// in the database's CLUT folder: a dictionary of its curves (arrays of
    /// point NSValues) and their colours. A named colour holds strings.
    @objc public static let legacyCLUTClassNames: Set<String> = [
        "NSObject", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
        "NSString", "NSMutableString", "NSNumber", "NSValue", "NSColor",
    ]

    /// The curves and colours of a legacy CLUT file, under "curves" and
    /// "colors" as mutable arrays of mutable arrays - points as NSValues,
    /// colours in calibrated RGB - or nil, logged, when the file is refused.
    /// The CLUT editor and the VR preset previews both read these files here.
    /// The file itself is never changed.
    @objc(legacyCLUTWithContentsOfFile:)
    public static func legacyCLUT(atPath path: String?) -> NSDictionary? {
        guard let path, let data = FileManager.default.contents(atPath: path) else { return nil }
        do {
            return try legacyCLUT(with: data)
        } catch {
            NSLog("Refused the CLUT %@: %@", (path as NSString).lastPathComponent, "\(error)")
            return nil
        }
    }

    /// A legacy CLUT, decoded with `legacyCLUTClassNames` only and then
    /// checked as `checkedCLUT` checks every 16-bit CLUT.
    public static func legacyCLUT(with data: Data) throws -> NSDictionary {
        let root = try unarchiveObject(with: data, allowedClassNames: legacyCLUTClassNames)
        guard let dictionary = root as? NSDictionary else {
            throw RestrictedUnarchiverError.invalidValue("the archive holds a \(type(of: root)), not a CLUT dictionary")
        }
        return try checkedCLUT(curves: dictionary.object(forKey: "curves"), colors: dictionary.object(forKey: "colors"),
                               point: clutPoint, color: clutColor)
    }

    /// The one check of a 16-bit CLUT, archived or in a property list: as
    /// many colour sets as curves, a colour for each point, no empty curve,
    /// finite points with an opacity in 0...1, and colours with an RGB form
    /// whose components are finite and in 0...1. `point` and `color` read one
    /// element of the format, nil for one of another type or outside that
    /// domain. The VRView reads the curves and colours in parallel, so a CLUT
    /// is taken whole or not at all.
    private static func checkedCLUT(curves: Any?, colors: Any?,
                                    point readPoint: (Any) -> NSPoint?,
                                    color readColor: (Any) -> NSColor?) throws -> NSDictionary {
        guard let curves = curves as? NSArray, let colors = colors as? NSArray else {
            throw RestrictedUnarchiverError.invalidValue("the CLUT has no arrays of curves and colours")
        }
        guard curves.count > 0, curves.count == colors.count else {
            throw RestrictedUnarchiverError.invalidValue("the CLUT has \(curves.count) curves and \(colors.count) colour sets")
        }
        let checkedCurves = NSMutableArray(capacity: curves.count)
        let checkedColors = NSMutableArray(capacity: colors.count)
        for index in 0..<curves.count {
            guard let curve = curves.object(at: index) as? NSArray,
                  let curveColors = colors.object(at: index) as? NSArray,
                  curve.count > 0, curve.count == curveColors.count else {
                throw RestrictedUnarchiverError.invalidValue("curve \(index) is not an array of points with a colour for each")
            }
            let points = NSMutableArray(capacity: curve.count)
            let pointColors = NSMutableArray(capacity: curve.count)
            for j in 0..<curve.count {
                guard let point = readPoint(curve.object(at: j)) else {
                    throw RestrictedUnarchiverError.invalidValue("point \(j) of curve \(index) is not a finite point with an opacity in 0...1")
                }
                guard let color = readColor(curveColors.object(at: j)) else {
                    throw RestrictedUnarchiverError.invalidValue("colour \(j) of curve \(index) is not an RGB colour with components in 0...1")
                }
                points.add(NSValue(point: point))
                pointColors.add(color)
            }
            checkedCurves.add(points)
            checkedColors.add(pointColors)
        }
        return NSDictionary(objects: [checkedCurves, checkedColors], forKeys: ["curves" as NSString, "colors" as NSString])
    }

    /// A point inside the domain of a curve: finite, with an opacity (y) in 0...1.
    private static func clutPointInDomain(_ point: NSPoint) -> NSPoint? {
        guard point.x.isFinite, point.y.isFinite, point.y >= 0, point.y <= 1 else { return nil }
        return point
    }

    /// A point of a curve: an NSValue of an NSPoint, as a 64-bit or a 32-bit
    /// application archived it, finite, with an opacity (y) in 0...1.
    private static func clutPoint(_ object: Any) -> NSPoint? {
        guard let value = object as? NSValue, !(value is NSNumber) else { return nil }
        let point: NSPoint
        switch String(cString: value.objCType) {
        case "{CGPoint=dd}", "{_NSPoint=dd}":
            var double = NSPoint.zero
            value.getValue(&double, size: MemoryLayout<NSPoint>.size)
            point = double
        case "{CGPoint=ff}", "{_NSPoint=ff}":
            var float: (Float, Float) = (0, 0)
            value.getValue(&float, size: MemoryLayout<(Float, Float)>.size)
            point = NSPoint(x: CGFloat(float.0), y: CGFloat(float.1))
        default:
            return nil
        }
        return clutPointInDomain(point)
    }

    /// A colour of a curve in calibrated RGB, as the VRView reads its
    /// components; nil for one with no RGB form or a component outside 0...1.
    private static func clutColor(_ object: Any) -> NSColor? {
        guard let color = (object as? NSColor)?.usingColorSpace(.genericRGB) else { return nil }
        for component in [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent] {
            if !component.isFinite || component < 0 || component > 1 { return nil }
        }
        return color
    }

    // MARK: - 16-bit CLUTs in property lists

    /// A 16-bit CLUT as the editor saves it - a .plist in the database's CLUT
    /// folder or in the bundle's - read with `plistCLUT(curves:colors:)`; nil
    /// when the file is no dictionary or is refused (logged). A dictionary
    /// with neither curves nor colours, such as an 8-bit CLUT of the bundle,
    /// is no 16-bit CLUT and is nil without a word.
    @objc(CLUTWithContentsOfPlistFile:)
    public static func plistCLUT(atPath path: String?) -> NSDictionary? {
        guard let path else { return nil }
        let name = (path as NSString).lastPathComponent
        guard let dictionary = NSDictionary(contentsOfFile: path) else {
            if FileManager.default.fileExists(atPath: path) { NSLog("Refused the CLUT %@: not a property list dictionary", name) }
            return nil
        }
        let curves = dictionary.object(forKey: "curves"), colors = dictionary.object(forKey: "colors")
        if curves == nil && colors == nil { return nil }
        return plistCLUT(curves: curves, colors: colors, source: name)
    }

    /// `plistCLUT(curves:colors:)`, or nil - logged with `source` - when the
    /// CLUT is refused. The 3D states and presets keep their CLUT under
    /// "16bitClutCurves" and "16bitClutColors".
    @objc(CLUTWithPlistCurves:colors:source:)
    public static func plistCLUT(curves: Any?, colors: Any?, source: String) -> NSDictionary? {
        do {
            return try plistCLUT(curves: curves, colors: colors)
        } catch {
            NSLog("Refused the CLUT %@: %@", source, "\(error)")
            return nil
        }
    }

    /// The curves and colours of a CLUT in a property list - points as
    /// {x, y} and colours as {red, green, blue}, all numbers - under "curves"
    /// and "colors" as mutable arrays of mutable arrays of point NSValues and
    /// calibrated RGB colours, as a legacy CLUT reads, after the same check.
    public static func plistCLUT(curves: Any?, colors: Any?) throws -> NSDictionary {
        return try checkedCLUT(curves: curves, colors: colors, point: plistCLUTPoint, color: plistCLUTColor)
    }

    /// A number of a property list CLUT as the editor saves it, as a float
    /// (its precision); nil for anything else, a boolean included.
    private static func plistCLUTNumber(_ object: Any?) -> Float? {
        guard let number = object as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.floatValue
    }

    /// A point of a property list curve, {x, y}, in the domain of a curve.
    static func plistCLUTPoint(_ object: Any) -> NSPoint? {
        guard let dictionary = object as? NSDictionary,
              let x = plistCLUTNumber(dictionary.object(forKey: "x")),
              let y = plistCLUTNumber(dictionary.object(forKey: "y")) else { return nil }
        return clutPointInDomain(NSPoint(x: CGFloat(x), y: CGFloat(y)))
    }

    /// A colour of a property list curve, {red, green, blue} each finite and
    /// in 0...1, as an opaque calibrated RGB colour.
    static func plistCLUTColor(_ object: Any) -> NSColor? {
        guard let dictionary = object as? NSDictionary,
              let red = plistCLUTNumber(dictionary.object(forKey: "red")),
              let green = plistCLUTNumber(dictionary.object(forKey: "green")),
              let blue = plistCLUTNumber(dictionary.object(forKey: "blue")) else { return nil }
        for component in [red, green, blue] where !component.isFinite || component < 0 || component > 1 {
            return nil
        }
        return NSColor(calibratedRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
    }

    // MARK: - Sort descriptors of the database albums

    /// The selectors the browser's columns sort with (their prototypes in
    /// MainMenu.xib, and the default sort by name), and Foundation's other
    /// string comparisons.
    public static let sortSelectorNames: Set<String> = [
        "compare:", "caseInsensitiveCompare:", "localizedCompare:",
        "localizedCaseInsensitiveCompare:", "localizedStandardCompare:",
    ]

    /// The sort descriptors saved for an album in the database's
    /// AlbumSortDescriptors.plist: a keyed archive of an array of them, read
    /// with secure coding and only these two classes. Each must sort by a
    /// plain key path with one of `sortSelectorNames`; only then is it
    /// allowed to evaluate. Nil, logged, when the value is refused.
    @objc(unarchiveSortDescriptorsWithData:)
    public static func sortDescriptors(with data: Data?) -> [NSSortDescriptor]? {
        guard let data, !data.isEmpty else { return nil }
        var object: Any?
        do {
            try HorosObjCException.perform {
                object = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSArray.self, NSSortDescriptor.self], from: data)
            }
        } catch {
            object = nil
        }
        guard let array = object as? NSArray else {
            NSLog("Refused the sort descriptors of %lu bytes: not a secure archive of an array of sort descriptors", data.count)
            return nil
        }
        var descriptors: [NSSortDescriptor] = []
        for element in array {
            guard let descriptor = element as? NSSortDescriptor,
                  let key = descriptor.key, isPlainKeyPath(key),
                  sortSelectorNames.contains(NSStringFromSelector(descriptor.selector ?? #selector(NSNumber.compare(_:)))) else {
                NSLog("Refused the sort descriptors of %lu bytes: %@ does not sort by a plain key with a known comparison",
                      data.count, "\(element)")
                return nil
            }
            descriptor.allowEvaluation()
            descriptors.append(descriptor)
        }
        return descriptors
    }

    /// Identifiers joined by dots: no collection operator, no other character.
    private static func isPlainKeyPath(_ key: String) -> Bool {
        return !key.isEmpty && key.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { part in
            guard let first = part.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else {
                return false
            }
            return part.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
        }
    }

    // MARK: - Archived values of N2UserDefaults

    /// What a property list holds, and NSObject, their superclass.
    public static let propertyListClassNames: Set<String> = [
        "NSObject", "NSString", "NSMutableString", "NSNumber", "NSData", "NSMutableData",
        "NSDate", "NSArray", "NSMutableArray", "NSDictionary", "NSMutableDictionary",
    ]

    /// The object of an NSArchiver value when it is an instance of `aClass`,
    /// decoded with only that class, its superclasses and the property list
    /// classes; nil, logged, otherwise.
    @objc(unarchiveObjectWithData:ofClass:)
    public static func unarchiveObject(with data: Data?, ofClass aClass: AnyClass) -> Any? {
        var allowed = propertyListClassNames
        var current: AnyClass? = aClass
        while let cls = current {
            allowed.insert(NSStringFromClass(cls))
            current = class_getSuperclass(cls)
        }
        guard let object = unarchiveObjectOrNil(with: data, allowedClassNames: allowed) else { return nil }
        return (object as AnyObject).isKind(of: aClass) ? object : nil
    }
}

/// A walk over a typedstream - NSArchiver's format, unchanged since NeXTSTEP -
/// that records every class name in it and reads nothing into objects.
///
/// The stream: a version byte (4), the signature "streamtyped" (little-endian
/// numbers) or "typedstream" (big-endian), the system version (1000), then
/// groups. A group is a type string, shared, followed by one value per type in
/// it. Integers are one signed byte, or a tag followed by 2, 4 or 8 bytes;
/// reals are a tag followed by a float or double, or an integer. Strings and
/// objects are new (a tag), nil (a tag) or a reference to an earlier one. An
/// object is its class, then its groups, then an end tag; a class is its name
/// (a shared string), its version and its superclass, down to nil.
struct TypedStreamWalker {
    private static let tagInteger2: UInt8 = 0x81
    private static let tagInteger4: UInt8 = 0x82
    private static let tagFloatingPoint: UInt8 = 0x83
    private static let tagNew: UInt8 = 0x84
    private static let tagNil: UInt8 = 0x85
    private static let tagEndOfObject: UInt8 = 0x86
    private static let tagInteger8: UInt8 = 0x87
    /// Reference numbers start after the tags, at -110.
    private static let firstReference: Int64 = -110
    /// Deeper than any archive Horos writes (an array of arrays of ROIs whose
    /// dictionaries hold arrays of numbers), and shallow enough that neither
    /// this walk nor NSUnarchiver runs out of stack.
    private static let maximumDepth = 64

    private enum Entry {
        case object
        case classDefinition
        case cString
    }

    private indirect enum TypeCode {
        case char           // c C: one raw byte
        case integer        // s S i I l L q Q
        case float, double
        case object         // @
        case classValue     // #
        case selector       // :
        case cString        // *
        case bytes          // +: a length and that many bytes
        case array(Int, TypeCode)
        case structure([TypeCode])
    }

    private let bytes: [UInt8]
    private var position = 0
    private var bigEndian = false
    private var sharedStrings: [[UInt8]] = []
    private var entries: [Entry] = []
    private var depth = 0
    private(set) var classNames: [String] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private func failure(_ reason: String) -> RestrictedUnarchiverError {
        return .unreadable("not a typedstream this reader accepts: \(reason) at byte \(position)")
    }

    /// The header and the root object that +unarchiveObjectWithData: reads.
    /// NSUnarchiver reads nothing after it; the padding a DICOM value may add
    /// (zero bytes) is the only thing allowed there.
    mutating func walkRootObject() throws {
        guard try readByte() == 4 else { throw failure("unknown stream version") }
        let signature = try readUnsharedBytes()
        if signature == Array("streamtyped".utf8) {
            bigEndian = false
        } else if signature == Array("typedstream".utf8) {
            bigEndian = true
        } else {
            throw failure("unknown signature")
        }
        guard try readInteger() == 1000 else { throw failure("unknown system version") }
        let types = try readTypeString()
        guard types.count == 1, case .object = types[0] else { throw failure("the root is not an object") }
        try walkObject()
        if bytes[position...].contains(where: { $0 != 0 }) {
            throw failure("data after the root object")
        }
    }

    // MARK: Primitive values

    private mutating func readByte() throws -> UInt8 {
        guard position < bytes.count else { throw failure("unexpected end") }
        defer { position += 1 }
        return bytes[position]
    }

    private mutating func peekByte() throws -> UInt8 {
        guard position < bytes.count else { throw failure("unexpected end") }
        return bytes[position]
    }

    private mutating func readRaw(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - position else { throw failure("a length past the end") }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    private mutating func readFixed(_ count: Int) throws -> UInt64 {
        let raw = try readRaw(count)
        var value: UInt64 = 0
        for byte in (bigEndian ? raw : raw.reversed()) {
            value = value << 8 | UInt64(byte)
        }
        return value
    }

    private mutating func readInteger() throws -> Int64 {
        return try readInteger(head: try readByte())
    }

    private mutating func readInteger(head: UInt8) throws -> Int64 {
        switch head {
        case Self.tagInteger2: return Int64(Int16(truncatingIfNeeded: try readFixed(2)))
        case Self.tagInteger4: return Int64(Int32(truncatingIfNeeded: try readFixed(4)))
        case Self.tagInteger8: return Int64(bitPattern: try readFixed(8))
        case 0x80...0x91: throw failure("tag \(head) where an integer belongs")
        default: return Int64(Int8(bitPattern: head))
        }
    }

    private mutating func readReal(size: Int) throws {
        let head = try readByte()
        if head == Self.tagFloatingPoint {
            _ = try readRaw(size)
        } else {
            _ = try readInteger(head: head)
        }
    }

    private mutating func readUnsharedBytes() throws -> [UInt8] {
        let length = try readInteger()
        guard length >= 0, length <= Int64(bytes.count - position) else { throw failure("a length past the end") }
        return try readRaw(Int(length))
    }

    /// A reference number, as an index into a table of `count` entries.
    private mutating func readReference(head: UInt8, count: Int) throws -> Int {
        let index = try readInteger(head: head) - Self.firstReference
        guard index >= 0, index < Int64(count) else { throw failure("a reference to nothing") }
        return Int(index)
    }

    private mutating func readSharedString() throws -> [UInt8]? {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return nil
        case Self.tagNew:
            let string = try readUnsharedBytes()
            sharedStrings.append(string)
            return string
        default:
            return sharedStrings[try readReference(head: head, count: sharedStrings.count)]
        }
    }

    // MARK: Objects and classes

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maximumDepth else { throw failure("nesting deeper than \(Self.maximumDepth)") }
    }

    private mutating func walkObject() throws {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return
        case Self.tagNew:
            try enter()
            defer { depth -= 1 }
            entries.append(.object)
            guard try walkClass() else { throw failure("an object without a class") }
            while try peekByte() != Self.tagEndOfObject {
                try walkGroup()
            }
            position += 1
        default:
            guard case .object = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("an object reference to something else")
            }
        }
    }

    /// False for nil, the end of a superclass chain.
    private mutating func walkClass() throws -> Bool {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return false
        case Self.tagNew:
            try enter()
            defer { depth -= 1 }
            guard let nameBytes = try readSharedString(), !nameBytes.isEmpty, !nameBytes.contains(0),
                  let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw failure("a class without a readable name")
            }
            classNames.append(name)
            _ = try readInteger() // version
            entries.append(.classDefinition)
            _ = try walkClass() // superclass
            return true
        default:
            guard case .classDefinition = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("a class reference to something else")
            }
            return true
        }
    }

    private mutating func walkCString() throws {
        let head = try readByte()
        switch head {
        case Self.tagNil:
            return
        case Self.tagNew:
            entries.append(.cString)
            guard try readSharedString() != nil else { throw failure("a C string without characters") }
        default:
            guard case .cString = entries[try readReference(head: head, count: entries.count)] else {
                throw failure("a C string reference to something else")
            }
        }
    }

    // MARK: Groups and type strings

    private mutating func walkGroup() throws {
        for type in try readTypeString() {
            try walkValue(type)
        }
    }

    private mutating func walkValue(_ type: TypeCode) throws {
        switch type {
        case .char: _ = try readByte()
        case .integer: _ = try readInteger()
        case .float: try readReal(size: 4)
        case .double: try readReal(size: 8)
        case .object: try walkObject()
        case .classValue: _ = try walkClass()
        case .selector: _ = try readSharedString()
        case .cString: try walkCString()
        case .bytes: _ = try readUnsharedBytes()
        case .array(let count, .char):
            _ = try readRaw(count)
        case .array(let count, let element):
            // Each element takes at least a byte, so a count past the end is
            // not an archive; it would only make the walk long.
            guard count <= bytes.count - position else { throw failure("an array past the end") }
            try enter()
            defer { depth -= 1 }
            for _ in 0..<count {
                try walkValue(element)
            }
        case .structure(let fields):
            try enter()
            defer { depth -= 1 }
            for field in fields {
                try walkValue(field)
            }
        }
    }

    private mutating func readTypeString() throws -> [TypeCode] {
        guard let string = try readSharedString(), !string.isEmpty else { throw failure("a group without a type") }
        var index = 0
        var types: [TypeCode] = []
        while index < string.count {
            types.append(try parseType(string, &index, nesting: 0))
        }
        return types
    }

    private func parseType(_ string: [UInt8], _ index: inout Int, nesting: Int) throws -> TypeCode {
        guard nesting < 16 else { throw failure("a type nested too deep") }
        guard index < string.count else { throw failure("a truncated type") }
        let code = string[index]
        index += 1
        switch code {
        case UInt8(ascii: "c"), UInt8(ascii: "C"):
            return .char
        case UInt8(ascii: "s"), UInt8(ascii: "S"), UInt8(ascii: "i"), UInt8(ascii: "I"),
             UInt8(ascii: "l"), UInt8(ascii: "L"), UInt8(ascii: "q"), UInt8(ascii: "Q"):
            return .integer
        case UInt8(ascii: "f"): return .float
        case UInt8(ascii: "d"): return .double
        case UInt8(ascii: "@"): return .object
        case UInt8(ascii: "#"): return .classValue
        case UInt8(ascii: ":"): return .selector
        case UInt8(ascii: "*"): return .cString
        case UInt8(ascii: "+"): return .bytes
        case UInt8(ascii: "["):
            var count = 0
            var digits = 0
            while index < string.count, string[index] >= UInt8(ascii: "0"), string[index] <= UInt8(ascii: "9") {
                count = count * 10 + Int(string[index] - UInt8(ascii: "0"))
                digits += 1
                index += 1
                guard digits <= 9 else { throw failure("an array too long") }
            }
            guard digits > 0 else { throw failure("an array without a count") }
            let element = try parseType(string, &index, nesting: nesting + 1)
            guard index < string.count, string[index] == UInt8(ascii: "]") else { throw failure("an unterminated array type") }
            index += 1
            if case .char = element {
                return .array(count, element)
            }
            guard count > 0 else { throw failure("an empty array type") }
            return .array(count, element)
        case UInt8(ascii: "{"):
            // The name, up to '=', then the fields up to '}'.
            while index < string.count, string[index] != UInt8(ascii: "=") {
                guard !"{}[]\"".utf8.contains(string[index]) else { throw failure("a malformed structure type") }
                index += 1
            }
            guard index < string.count else { throw failure("a structure type without fields") }
            index += 1
            var fields: [TypeCode] = []
            while index < string.count, string[index] != UInt8(ascii: "}") {
                fields.append(try parseType(string, &index, nesting: nesting + 1))
            }
            guard index < string.count, !fields.isEmpty else { throw failure("a malformed structure type") }
            index += 1
            return .structure(fields)
        default:
            throw failure("the unsupported type '\(Character(Unicode.Scalar(code)))'")
        }
    }
}
