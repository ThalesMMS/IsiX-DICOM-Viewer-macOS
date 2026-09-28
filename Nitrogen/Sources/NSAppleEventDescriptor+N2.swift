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

// NSObject (Scripting), NSAppleEventDescriptor (Scripting) and NSDictionary
// (Scripting) are implemented in Swift since #710. The selectors and
// <Horos/NSAppleEventDescriptor+N2.h> are those of the former categories.

/// A four-character code, as the Objective-C 'abcd' literal.
fileprivate func fourCharCode(_ code: StaticString) -> DescType {
    precondition(code.utf8CodeUnitCount == 4)
    return code.withUTF8Buffer { $0.reduce(0) { $0 << 8 | DescType($1) } }
}

/// NSAssert, which the Objective-C left enabled in every configuration: the
/// current NSAssertionHandler gets the failure, and by default raises
/// NSInternalInconsistencyException. The descriptions have no format
/// specifiers, so the variadic method is called with none.
fileprivate func assertion(_ condition: Bool, _ description: NSString, in selector: Selector, object: AnyObject, line: Int = #line) {
    if condition { return }
    let handler = NSAssertionHandler.current
    let handleFailure = NSSelectorFromString("handleFailureInMethod:object:file:lineNumber:description:")
    typealias HandleFailure = @convention(c) (AnyObject, Selector, Selector, AnyObject, NSString, Int, NSString) -> Void
    let function = unsafeBitCast(handler.method(for: handleFailure), to: HandleFailure.self)
    function(handler, handleFailure, selector, object, "NSAppleEventDescriptor+N2.swift", line, description)
}

/// -addObject: and -setObject:forKey: as the Objective-C sent them: a nil
/// object raises NSInvalidArgumentException there, as it did.
fileprivate func add(_ object: Any?, to list: NSMutableArray) {
    list.perform(#selector(NSMutableArray.add(_:)), with: object)
}

fileprivate func set(_ object: Any?, forKey key: Any?, in dictionary: NSMutableDictionary) {
    dictionary.perform(#selector(NSMutableDictionary.setObject(_:forKey:)), with: object, with: key)
}

/// The value of the first `MemoryLayout<T>.size` bytes of `data`.
fileprivate func bytesValue<T>(of data: Data, _ initial: T) -> T {
    var temp = initial
    withUnsafeMutableBytes(of: &temp) { (data as NSData).getBytes($0.baseAddress!, length: $0.count) }
    return temp
}

/// The four characters of a DescType in memory order reversed, as the
/// Objective-C "%c%c%c%c" of c[3], c[2], c[1], c[0].
fileprivate func fourCharacters(_ type: UInt32) -> [CVarArg] {
    withUnsafeBytes(of: type) { bytes in
        [CChar(bitPattern: bytes[3]), CChar(bitPattern: bytes[2]), CChar(bitPattern: bytes[1]), CChar(bitPattern: bytes[0])]
    }
}

/// The names of the record keys AppleScript compiles to a code rather than a
/// user field: the terms of Horos.sdef, of AppleScript itself and of Standard
/// Additions, each as it compiles inside `tell application "Horos"` (checked
/// by tests/test-applescript-xmlrpc-parameters.py). Where several words share
/// a code ("text" and "rich text", "file" and "files", "port" and "Port") the
/// common one is kept.
fileprivate let recordKeyNames: [DescType: String] = {
    let terms: KeyValuePairs<String, String> = [
        // Horos.sdef and AppleScript
        "pnam": "name", "ID  ": "id", "vers": "version", "pALL": "properties",
        "pcnt": "contents", "kind": "kind", "type": "type", "file": "file", "ctxt": "text",
        "TEXT": "string", "ldt ": "date", "pidx": "index", "cRGB": "color", "ptsz": "size",
        "font": "font", "pbnd": "bounds", "pvis": "visible", "pisf": "frontmost", "sele": "selection",
        "imod": "modified", "hclb": "closeable", "ismn": "minimizable", "pmnd": "minimized",
        "prsz": "resizable", "iszm": "zoomable", "pzum": "zoomed", "atfn": "file name",
        "atts": "attachment", "catr": "attribute run", "cha ": "character", "cobj": "item",
        "cpar": "paragraph", "cwor": "word", "cwin": "window", "docu": "document", "capp": "application",
        "txst": "style", "pset": "print settings", "lwcp": "copies", "lwcl": "collating",
        "lwfp": "starting page", "lwlp": "ending page", "lwla": "pages across", "lwld": "pages down",
        "lweh": "error handling", "faxn": "fax number", "trpr": "target printer",
        "****": "anything", "alis": "alias", "bool": "boolean", "long": "integer", "doub": "real",
        "nmbr": "number", "list": "list", "reco": "record", "null": "null", "enum": "constant",
        "obj ": "reference", "scpt": "script", "hand": "handler", "evnt": "event", "leng": "length",
        "rest": "rest", "rvse": "reverse", "rdat": "data", "PICT": "picture", "snd ": "sound",
        "QDpt": "point", "qdrt": "rectangle", "kMsg": "key", "time": "time", "day ": "day",
        "wkdy": "weekday", "mnth": "month", "year": "year", "hour": "hours", "min ": "minutes",
        "scnd": "seconds",
        // Standard Additions
        "url ": "URL", "FTPc": "path", "HOST": "host", "ppor": "port", "pusc": "scheme",
        "RAun": "user name", "RApw": "password", "IPAD": "Internet address", "pDNS": "DNS form",
        "pipd": "dotted decimal form", "ldsa": "host name", "html": "web page", "psxf": "POSIX file",
        "psxp": "POSIX path", "ascd": "creation date", "asmo": "modification date", "asct": "file creator",
        "asty": "file type", "asda": "default application", "asdr": "folder", "asfe": "file information",
        "asfw": "folder window", "aslk": "locked", "aslv": "long version", "assv": "short version",
        "bnid": "bundle identifier", "bzst": "busy status", "cfbn": "short name", "dnam": "displayed name",
        "hidx": "extension hidden", "ispk": "package folder", "nmxt": "name extension", "ptxe": "text encoding",
        "utid": "type identifier", "home": "home directory", "aleR": "alert reply", "askr": "dialog reply",
        "bhit": "button returned", "ttxt": "text returned", "gavu": "gave up", "vlst": "volume settings",
        "ouvl": "output volume", "invl": "input volume", "alvl": "alert volume", "mute": "output muted",
        "sirr": "system information", "siav": "AppleScript version", "sikv": "AppleScript Studio version",
        "sisv": "system version", "sisn": "short user name", "siln": "long user name", "siid": "user ID",
        "siul": "user locale", "sibv": "boot volume", "sicn": "computer name", "sict": "CPU type",
        "sics": "CPU speed", "sipm": "physical memory", "siea": "primary Ethernet address",
        "siip": "IPv4 address",
    ]
    var names: [DescType: String] = [:]
    for (code, name) in terms {
        let keyword = code.utf8.reduce(0) { $0 << 8 | DescType($1) }
        precondition(code.utf8.count == 4 && names[keyword] == nil)
        names[keyword] = name
    }
    return names
}()

/// The dictionary key of a record field that is not a user field: the name of
/// its term, or, for a code no terminology here knows (a «class abcd» key, a
/// term of another application), its four characters.
fileprivate func recordKey(for keyword: AEKeyword) -> String {
    recordKeyNames[keyword] ?? NSString(format: "%c%c%c%c", arguments: getVaList(fourCharacters(keyword))) as String
}

/// The classes an 'ObjC' descriptor may hold: those of a property list, and
/// NSNull.
fileprivate let archivedValueClasses: [AnyClass] = [NSString.self, NSNumber.self, NSData.self, NSDate.self,
                                                    NSArray.self, NSDictionary.self, NSNull.self]

public extension NSAppleEventDescriptor {

    /// Not in the header; kept under its former selector.
    @objc(descriptorWithObject:)
    static func descriptor(withObject object: Any?) -> NSAppleEventDescriptor? {
        guard let object, !(object is NSNull) else {
            return NSAppleEventDescriptor.null()
        }

        if let dictionary = object as? NSDictionary {
            let ka = dictionary.allKeys as NSArray
            let kv = dictionary.allValues as NSArray

            let list = NSMutableArray(capacity: ka.count + kv.count)
            for i in 0..<dictionary.count {
                list.add(ka.object(at: i))
                list.add(kv.object(at: i))
            }

            let recoAed = NSAppleEventDescriptor.record()
            recoAed.setDescriptor(descriptor(withObject: list)!, forKeyword: fourCharCode("usrf"))
            return recoAed
        }

        if let array = object as? NSArray {
            let listAed = NSAppleEventDescriptor.list()
            for i in 0..<array.count {
                listAed.insert(descriptor(withObject: array.object(at: i))!, at: i + 1)
            }
            return listAed
        }

        if let string = object as? NSString {
            return NSAppleEventDescriptor(string: string as String)
        }

        if let number = object as? NSNumber {
            switch UInt8(bitPattern: number.objCType[0]) {
            case UInt8(ascii: "c"):
                var temp = number.int8Value // 'cha ': char
                return NSAppleEventDescriptor(descriptorType: fourCharCode("cha "), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            case UInt8(ascii: "i"):
                return NSAppleEventDescriptor(int32: number.int32Value) // 'long': integer
            case UInt8(ascii: "s"):
                var temp = number.int16Value // 'shor': small integer
                return NSAppleEventDescriptor(descriptorType: fourCharCode("shor"), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            case UInt8(ascii: "l"), UInt8(ascii: "q"):
                var temp = number.intValue // 'comp': double integer
                return NSAppleEventDescriptor(descriptorType: fourCharCode("comp"), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            // 'C'
            case UInt8(ascii: "I"):
                var temp = number.uint32Value // 'magn': unsigned integer
                return NSAppleEventDescriptor(descriptorType: fourCharCode("magn"), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            // 'S'
            // 'L'
            // 'Q'
            case UInt8(ascii: "f"):
                var temp = number.floatValue // 'sing': small real
                return NSAppleEventDescriptor(descriptorType: fourCharCode("sing"), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            case UInt8(ascii: "d"):
                var temp = number.doubleValue // 'doub': real
                return NSAppleEventDescriptor(descriptorType: fourCharCode("doub"), bytes: &temp, length: MemoryLayout.size(ofValue: temp))
            case UInt8(ascii: "B"):
                return NSAppleEventDescriptor(boolean: number.boolValue) // 'bool': boolean
            default:
                break
            }

            NSException(name: .genericException,
                        reason: String(format: "unknown NSAppleEventDescriptor type for NSNumber with ObjC type %s", number.objCType),
                        userInfo: nil).raise()
        }

        var archived: NSAppleEventDescriptor?
        do {
            try HorosObjCException.perform {
                archived = NSAppleEventDescriptor(descriptorType: fourCharCode("ObjC"), data: NSKeyedArchiver.archivedData(withRootObject: object))
            }
            return archived
        } catch {
            let exception = (error as NSError).userInfo[HorosObjCExceptionKey] as? NSException
            NSLog("tried to use archivedDataWithRootObject but failed: %@", (exception?.description ?? "(null)") as NSString)
        }

        NSException(name: .genericException,
                    reason: String(format: "unknown NSAppleEventDescriptor type for class %@", (object as AnyObject).className as NSString),
                    userInfo: nil).raise()

        return nil
    }

    /// Not in the header; kept under its former selector.
    @objc(objectWithDescriptor:)
    static func object(with descriptor: NSAppleEventDescriptor) -> Any? {
        let selector = #selector(NSAppleEventDescriptor.object(with:))
        switch descriptor.descriptorType {
        case fourCharCode("null") /* typeNull */, fourCharCode("msng"):
            return NSNull()
        case fourCharCode("reco") /* typeAERecord */:
            // A key written as an identifier or between bars is a user field,
            // in the one 'usrf' list; a key that is a term of the dictionary
            // AppleScript compiled against (name, id, path, URL…) arrives as a
            // field of its own under the term's code ('pnam', 'ID  ', 'FTPc',
            // 'url '…), and is given back its name.
            let fields = NSMutableDictionary(capacity: descriptor.numberOfItems)
            var userFields: NSDictionary?
            for i in stride(from: 1, through: descriptor.numberOfItems, by: 1) {
                let keyword = descriptor.keywordForDescriptor(at: i)
                let field = descriptor.atIndex(i)
                if keyword == fourCharCode("usrf") {
                    assertion(field?.descriptorType == fourCharCode("list"), "'reco' subrecord should be of type 'list'", in: selector, object: self)
                    userFields = dictionary(with: field?.object() as? NSArray)
                } else {
                    set(field?.object(), forKey: recordKey(for: keyword), in: fields)
                }
            }
            // A user field wins over a term of the same name: {name:1, |name|:2}.
            if let userFields {
                fields.addEntries(from: userFields as! [AnyHashable: Any])
            }
            return fields.copy()
        case fourCharCode("list") /* typeAEList */:
            let list = NSMutableArray(capacity: descriptor.numberOfItems)
            for i in 0..<descriptor.numberOfItems {
                add(descriptor.atIndex(i + 1)?.object(), to: list)
            }
            return list.copy()
        case fourCharCode("utxt") /* typeUnicodeText */:
            return descriptor.stringValue
        case fourCharCode("cha "):
            return NSNumber(value: bytesValue(of: descriptor.data, Int8(0)))
        case fourCharCode("long") /* typeSInt32 */:
            return NSNumber(value: bytesValue(of: descriptor.data, Int32(0)))
        case fourCharCode("shor") /* typeSInt16 */:
            return NSNumber(value: bytesValue(of: descriptor.data, Int16(0)))
        case fourCharCode("comp") /* typeSInt64 */:
            return NSNumber(value: Int(bytesValue(of: descriptor.data, Int64(0))))
        case fourCharCode("magn") /* typeUInt32 */:
            return NSNumber(value: bytesValue(of: descriptor.data, UInt32(0)))
        case fourCharCode("sing") /* typeIEEE32BitFloatingPoint */:
            return NSNumber(value: bytesValue(of: descriptor.data, Float32(0)))
        case fourCharCode("doub") /* typeIEEE64BitFloatingPoint */:
            return NSNumber(value: bytesValue(of: descriptor.data, Float64(0)))
        case fourCharCode("bool") /* typeBoolean */:
            return NSNumber(value: bytesValue(of: descriptor.data, false))
        // AppleScript literals can return zero-payload 'true'/'fals' descriptors,
        // not only a 'bool' descriptor with one data byte.
        case fourCharCode("true") /* typeTrue */:
            return NSNumber(value: true)
        case fourCharCode("fals") /* typeFalse */:
            return NSNumber(value: false)
        case fourCharCode("obj "):
            let dict = NSMutableDictionary()
            set(descriptor.atIndex(1)?.object(), forKey: "class", in: dict)
            set(descriptor.atIndex(2)?.object(), forKey: "container", in: dict)
            set(descriptor.atIndex(3)?.object(), forKey: "form", in: dict)
            set(descriptor.atIndex(4)?.object(), forKey: "data", in: dict)
            return dict
        case fourCharCode("enum") /* typeEnumerated */, fourCharCode("type") /* typeType */:
            return NSString(format: "%c%c%c%c", arguments: getVaList(fourCharacters(bytesValue(of: descriptor.data, UInt32(0)))))
        // 'exte': extended float
        // 'ldbl': 128 bits
        case fourCharCode("ObjC"):
            // A keyed archive, as +descriptorWithObject: makes of a value it
            // has no Apple Event type for; but the descriptor may come from
            // any process that can send Horos an Apple Event, so only
            // property-list classes are decoded, with secure coding. An
            // archive of any other class raises, as an unhandled type does,
            // without instantiating it.
            if let value = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: archivedValueClasses, from: descriptor.data) {
                return value
            }
            NSException(name: .genericException,
                        reason: "refused an 'ObjC' NSAppleEventDescriptor that is not a keyed archive of property-list values",
                        userInfo: nil).raise()
            return nil
        default:
            break
        }

        let type = descriptor.descriptorType
        NSException(name: .genericException,
                    reason: String(format: "unhandled NSAppleEventDescriptor of type '%c%c%c%c': %@",
                                   arguments: fourCharacters(type) + [(descriptor.stringValue ?? "(null)") as NSString]),
                    userInfo: nil).raise()

        return nil
    }

    @objc func object() -> Any? {
        NSAppleEventDescriptor.object(with: self)
    }

    @objc(dictionaryWithArray:)
    static func dictionary(with list: NSArray?) -> NSDictionary {
        let count = list?.count ?? 0
        assertion(count % 2 == 0, "'reco' subrecord 'list' should contain an even number of items",
                  in: #selector(NSAppleEventDescriptor.dictionary(with:)), object: self)
        let dictionary = NSMutableDictionary(capacity: count / 2)
        for i in 0..<count / 2 {
            set(list!.object(at: i * 2 + 1), forKey: list!.object(at: i * 2 + 0), in: dictionary)
        }
        return dictionary.copy() as! NSDictionary
    }
}

public extension NSObject {

    @objc func appleEventDescriptor() -> NSAppleEventDescriptor? {
        NSAppleEventDescriptor.descriptor(withObject: self)
    }
}

public extension NSDictionary {

    /// Cocoa Scripting's record coercion; not in the header, kept under its
    /// former selectors.
    @objc(scriptingRecordWithDescriptor:)
    static func scriptingRecord(with descriptor: NSAppleEventDescriptor) -> Any? {
        descriptor.object()
    }

    @objc func scriptingRecordDescriptor() -> Any? {
        NSLog("scriptingRecordDescriptor %@", description as NSString)
        let out = appleEventDescriptor()
        NSLog("outs %@", (out?.description ?? "(null)") as NSString)
        return out
    }
}
